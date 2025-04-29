#!/bin/bash
set -e

# Configuration
DOCKERHUB_USERNAME="creativsrwr"
WEBHOOK_NAME="disable-enablesvclinks-mutator"
NAMESPACE="webhook-demo"
IMAGE="${DOCKERHUB_USERNAME}/${WEBHOOK_NAME}:latest"
CERT_MANAGER_VERSION="v1.17.0"

# 1) Write main.go (mutating webhook only)
cat <<'EOF' > main.go
package main

import (
    "encoding/json"
    "fmt"
    "io/ioutil"
    "net/http"

    admissionv1 "k8s.io/api/admission/v1"
    appsv1      "k8s.io/api/apps/v1"
)

func mutateFunc(w http.ResponseWriter, r *http.Request) {
    var review admissionv1.AdmissionReview
    body, _ := ioutil.ReadAll(r.Body)
    _ = json.Unmarshal(body, &review)

    dep := appsv1.Deployment{}
    _ = json.Unmarshal(review.Request.Object.Raw, &dep)

    var patches []map[string]interface{}

    // If enableServiceLinks is unset or true, patch it to false
    if dep.Spec.Template.Spec.EnableServiceLinks == nil || *dep.Spec.Template.Spec.EnableServiceLinks {
        patches = append(patches, map[string]interface{}{
            "op":    "add",
            "path":  "/spec/template/spec/enableServiceLinks",
            "value": false,
        })
    }

    patchBytes, _ := json.Marshal(patches)
    pt := admissionv1.PatchTypeJSONPatch
    response := admissionv1.AdmissionResponse{
        UID:       review.Request.UID,
        Allowed:   true,
        Patch:     patchBytes,
        PatchType: &pt,
    }

    review.Response = &response
    respBytes, _ := json.Marshal(review)
    w.Header().Set("Content-Type", "application/json")
    w.Write(respBytes)
}

func main() {
    http.HandleFunc("/mutate", mutateFunc)
    fmt.Println("Starting mutating webhook on :8443")
    if err := http.ListenAndServeTLS(":8443", "/tls/tls.crt", "/tls/tls.key", nil); err != nil {
        fmt.Println("Failed to start server:", err)
    }
}
EOF

# 2) Write Dockerfile (use Go 1.24+ to satisfy k8s.io/api requirements)
cat <<'EOF' > Dockerfile
FROM golang:1.24-alpine AS builder
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

# 3) Build & push
echo "Building and pushing ${IMAGE}..."
docker build -t "${IMAGE}" .
docker push "${IMAGE}"

# 4) Ensure kind cluster exists
if ! kind get clusters | grep -q '^kind$'; then
  echo "Creating kind cluster..."
  kind create cluster --name kind
fi
kubectl cluster-info --context kind-kind

# 5) Install cert-manager if needed
if ! kubectl get deploy cert-manager -n cert-manager &>/dev/null; then
  echo "Installing cert-manager..."
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version "${CERT_MANAGER_VERSION}" \
    --set crds.enabled=true
fi
echo "Waiting for cert-manager..."
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s

# 6) Deploy Service & Deployment for mutator
echo "Deploying mutating webhook service & deployment..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
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
        - name: mutator
          image: ${IMAGE}
          imagePullPolicy: Always
          volumeMounts:
            - name: tls
              mountPath: /tls
              readOnly: true
      volumes:
        - name: tls
          projected:
            sources:
              - secret:
                  name: ${WEBHOOK_NAME}-tls
EOF

# 7) Create Issuer & Certificate
echo "Creating Issuer & Certificate..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: ${WEBHOOK_NAME}-issuer
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
  commonName: ${WEBHOOK_NAME}.${NAMESPACE}.svc
  dnsNames:
    - ${WEBHOOK_NAME}.${NAMESPACE}.svc
  issuerRef:
    name: ${WEBHOOK_NAME}-issuer
    kind: Issuer
  usages:
    - digital signature
    - key encipherment
EOF
kubectl -n "${NAMESPACE}" wait --for=condition=Ready certificate/${WEBHOOK_NAME}-tls --timeout=60s

# 8) Register MutatingWebhookConfiguration
echo "Registering MutatingWebhookConfiguration..."
CA_BUNDLE=$(kubectl get secret ${WEBHOOK_NAME}-tls -n ${NAMESPACE} \
  -o jsonpath='{.data.ca\.crt}')
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
        operations: ["CREATE","UPDATE"]
        scope: "Namespaced"
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 5
EOF

echo "✅ Mutating webhook deployed: all Deployments now default enableServiceLinks=false."

