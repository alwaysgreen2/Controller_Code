#!/bin/bash
set -e

DOCKERHUB_USERNAME="creativsrwr"
WEBHOOK_NAME="replica-enforcer"
NAMESPACE="webhook-demo"
IMAGE="${DOCKERHUB_USERNAME}/${WEBHOOK_NAME}:latest"
CERT_MANAGER_VERSION="v1.17.0"

cat <<EOF > main.go
package main

import (
    "encoding/json"
    "fmt"
    "io/ioutil"
    "net/http"
    "os"

    admissionv1 "k8s.io/api/admission/v1"
    appsv1 "k8s.io/api/apps/v1"
)

func admitFunc(w http.ResponseWriter, r *http.Request) {
    var review admissionv1.AdmissionReview
    body, _ := ioutil.ReadAll(r.Body)
    _ = json.Unmarshal(body, &review)

    deployment := appsv1.Deployment{}
    _ = json.Unmarshal(review.Request.Object.Raw, &deployment)

    patch := []byte("[]")
    allowed := true

    excludedNamespace := os.Getenv("EXCLUDED_NAMESPACE")
    if excludedNamespace == "" {
        excludedNamespace = "webhook-demo"
    }

    if review.Request.Kind.Kind == "Deployment" && review.Request.Namespace != excludedNamespace {
        replicas := int32(1)
        if deployment.Spec.Replicas != nil {
            replicas = *deployment.Spec.Replicas
        }
        if replicas < 3 {
            patch = []byte(\`[
                {"op": "replace", "path": "/spec/replicas", "value": 3}
            ]\`)
        }
    }

    response := admissionv1.AdmissionReview{
        TypeMeta: review.TypeMeta,
        Response: &admissionv1.AdmissionResponse{
            UID:     review.Request.UID,
            Allowed: allowed,
            Patch:   patch,
            PatchType: func() *admissionv1.PatchType {
                pt := admissionv1.PatchTypeJSONPatch
                return &pt
            }(),
        },
    }

    respBytes, _ := json.Marshal(response)
    w.Header().Set("Content-Type", "application/json")
    w.Write(respBytes)
}

func main() {
    http.HandleFunc("/mutate", admitFunc)
    fmt.Println("Starting webhook server on :8443")
    err := http.ListenAndServeTLS(":8443", "/tls/tls.crt", "/tls/tls.key", nil)
    if err != nil {
        fmt.Println("Failed to start server:", err)
    }
}
EOF

cat <<EOF > Dockerfile
FROM golang:1.23-alpine AS builder
WORKDIR /src
COPY main.go .
RUN go mod init webhook && go mod tidy && go build -o webhook .

FROM alpine:3.18
RUN adduser -D -H webhook
USER webhook
WORKDIR /home/webhook
COPY --from=builder /src/webhook .
ENTRYPOINT ["/home/webhook/webhook"]
EOF

echo "Build and push image to Docker Hub..."
docker build -t ${IMAGE} .
docker push ${IMAGE}

echo "Create kind cluster (if not exists)..."
if ! kind get clusters | grep -q '^kind$'; then
  kind create cluster --name kind
fi

kubectl cluster-info --context kind-kind

echo "Check if cert-manager is already installed..."
if kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
  echo "cert-manager already installed, skipping installation."
else
  echo "Installing cert-manager using Helm..."
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version ${CERT_MANAGER_VERSION} \
    --set crds.enabled=true
fi

echo "Waiting for cert-manager to be ready..."
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s

echo "Create namespace and deploy webhook Deployment/Service..."
kubectl create namespace ${NAMESPACE} || true

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${WEBHOOK_NAME}
  namespace: ${NAMESPACE}
spec:
  selector:
    app: ${WEBHOOK_NAME}
  ports:
    - port: 443
      targetPort: 8443
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${WEBHOOK_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${WEBHOOK_NAME}
  template:
    metadata:
      labels:
        app: ${WEBHOOK_NAME}
    spec:
      containers:
        - name: webhook
          image: ${IMAGE}
          imagePullPolicy: Always
          ports:
            - containerPort: 8443
          env:
            - name: EXCLUDED_NAMESPACE
              value: "${NAMESPACE}"
          volumeMounts:
            - name: webhook-certs
              mountPath: /tls
              readOnly: true
      volumes:
        - name: webhook-certs
          projected:
            sources:
              - secret:
                  name: ${WEBHOOK_NAME}-tls
EOF

echo "Create cert-manager Certificate and Issuer..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-issuer
  namespace: ${NAMESPACE}
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${WEBHOOK_NAME}-tls
  namespace: ${NAMESPACE}
spec:
  commonName: ${WEBHOOK_NAME}.${NAMESPACE}.svc
  dnsNames:
    - ${WEBHOOK_NAME}.${NAMESPACE}.svc
    - ${WEBHOOK_NAME}.${NAMESPACE}.svc.cluster.local
  secretName: ${WEBHOOK_NAME}-tls
  issuerRef:
    name: selfsigned-issuer
    kind: Issuer
  usages:
    - digital signature
    - key encipherment
EOF

echo "Waiting for webhook certificate to be ready..."
kubectl -n ${NAMESPACE} wait --for=condition=Ready certificate/${WEBHOOK_NAME}-tls --timeout=60s

echo "Create MutatingWebhookConfiguration..."
CA_BUNDLE=$(kubectl get secret ${WEBHOOK_NAME}-tls -n ${NAMESPACE} -o jsonpath='{.data.ca\.crt}')

cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: ${WEBHOOK_NAME}
webhooks:
  - name: ${WEBHOOK_NAME}.webhook-demo.svc
    clientConfig:
      service:
        name: ${WEBHOOK_NAME}
        namespace: ${NAMESPACE}
        path: "/mutate"
      caBundle: "${CA_BUNDLE}"
    rules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        resources: ["deployments"]
        operations: ["CREATE", "UPDATE"]
        scope: "Namespaced"
    namespaceSelector:
      matchExpressions:
        - key: "kubernetes.io/metadata.name"
          operator: "NotIn"
          values: ["${NAMESPACE}"]
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 2
EOF

echo "Mutating webhook deployed! Deployments with less than 3 replicas (except in ${NAMESPACE}) will be patched."

