#!/bin/bash
set -e

DOCKERHUB_USERNAME="creativsrwr"
WEBHOOK_NAME="readonly-rootfs-enforcer"
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
    admissionv1 "k8s.io/api/admission/v1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func admitFunc(w http.ResponseWriter, r *http.Request) {
    var review admissionv1.AdmissionReview
    body, _ := ioutil.ReadAll(r.Body)
    _ = json.Unmarshal(body, &review)

    allowed := true
    var result *metav1.Status = nil

    var pod struct {
        Spec struct {
            Containers []struct {
                SecurityContext *struct {
                    ReadOnlyRootFilesystem *bool \`json:"readOnlyRootFilesystem"\`
                } \`json:"securityContext"\`
            } \`json:"containers"\`
        } \`json:"spec"\`
    }
    _ = json.Unmarshal(review.Request.Object.Raw, &pod)

    for _, container := range pod.Spec.Containers {
        if container.SecurityContext == nil || container.SecurityContext.ReadOnlyRootFilesystem == nil || !*container.SecurityContext.ReadOnlyRootFilesystem {
            allowed = false
            result = &metav1.Status{
                Message: "All containers must set securityContext.readOnlyRootFilesystem=true.",
            }
            break
        }
    }

    response := admissionv1.AdmissionReview{
        TypeMeta: review.TypeMeta,
        Response: &admissionv1.AdmissionResponse{
            UID:     review.Request.UID,
            Allowed: allowed,
            Result:  result,
        },
    }
    respBytes, _ := json.Marshal(response)
    w.Header().Set("Content-Type", "application/json")
    w.Write(respBytes)
}

func main() {
    http.HandleFunc("/validate", admitFunc)
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

echo "Building and pushing image to Docker Hub..."
docker build -t ${IMAGE} .
docker push ${IMAGE}

echo "Creating kind cluster (if not exists)..."
if ! kind get clusters | grep -q '^kind$'; then
  kind create cluster --name kind
fi

kubectl cluster-info --context kind-kind

echo "Checking if cert-manager is installed..."
if kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
  echo "cert-manager already installed, skipping."
else
  echo "Installing cert-manager using Helm..."
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version ${CERT_MANAGER_VERSION} --set crds.enabled=true
fi

echo "Waiting for cert-manager to be ready..."
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s

echo "Creating namespace and deploying webhook resources..."
kubectl create namespace ${NAMESPACE} || true

cat <<EOF > manifests.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
---
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
          volumeMounts:
            - name: tls
              mountPath: /tls
              readOnly: true
      volumes:
        - name: tls
          secret:
            secretName: ${WEBHOOK_NAME}-tls
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: ${WEBHOOK_NAME}-selfsigned
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
  secretName: ${WEBHOOK_NAME}-tls
  issuerRef:
    name: ${WEBHOOK_NAME}-selfsigned
    kind: Issuer
  commonName: ${WEBHOOK_NAME}.${NAMESPACE}.svc
  dnsNames:
    - ${WEBHOOK_NAME}.${NAMESPACE}.svc
    - ${WEBHOOK_NAME}.${NAMESPACE}.svc.cluster.local
  usages:
    - digital signature
    - key encipherment
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: ${WEBHOOK_NAME}
  annotations:
    cert-manager.io/inject-ca-from: ${NAMESPACE}/${WEBHOOK_NAME}-tls
webhooks:
  - name: ${WEBHOOK_NAME}.${NAMESPACE}.svc
    clientConfig:
      service:
        name: ${WEBHOOK_NAME}
        namespace: ${NAMESPACE}
        path: /validate
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
        operations: ["CREATE"]
        scope: "Namespaced"
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 2
EOF

echo "Applying webhook manifests..."
kubectl apply -f manifests.yaml

echo "Waiting for webhook certificate to be ready..."
kubectl -n ${NAMESPACE} wait --for=condition=Ready certificate/${WEBHOOK_NAME}-tls --timeout=60s

echo "Webhook deployed!"
echo "You can now apply test pods to verify enforcement."

