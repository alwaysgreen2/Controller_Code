#!/bin/bash
set -e

# Configuration
DOCKERHUB_USERNAME="creativsrwr"
WEBHOOK_NAME="liveness-check-webhook"
NAMESPACE="webhook-demo"
IMAGE="${DOCKERHUB_USERNAME}/${WEBHOOK_NAME}:latest"
CERT_MANAGER_VERSION="v1.17.0"

# 1) Write main.go to enforce liveness probes and skip webhook-demo namespace
cat <<'EOF' > main.go
package main

import (
    "encoding/json"
    "fmt"
    "io/ioutil"
    "net/http"
    "strings"

    admissionv1 "k8s.io/api/admission/v1"
    appsv1      "k8s.io/api/apps/v1"
    metav1      "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func admitFunc(w http.ResponseWriter, r *http.Request) {
    var review admissionv1.AdmissionReview
    body, _ := ioutil.ReadAll(r.Body)
    _ = json.Unmarshal(body, &review)

    // Skip validation for exempt namespace
    if review.Request.Namespace == "webhook-demo" {
        response := admissionv1.AdmissionReview{
            TypeMeta: review.TypeMeta,
            Response: &admissionv1.AdmissionResponse{
                UID:     review.Request.UID,
                Allowed: true,
            },
        }
        respBytes, _ := json.Marshal(response)
        w.Header().Set("Content-Type", "application/json")
        w.Write(respBytes)
        return
    }

    dep := appsv1.Deployment{}
    _ = json.Unmarshal(review.Request.Object.Raw, &dep)

    var missing []string
    for _, c := range dep.Spec.Template.Spec.Containers {
        if c.LivenessProbe == nil {
            missing = append(missing, fmt.Sprintf("container %q missing liveness probe", c.Name))
        }
    }

    allowed := len(missing) == 0
    response := admissionv1.AdmissionReview{
        TypeMeta: review.TypeMeta,
        Response: &admissionv1.AdmissionResponse{
            UID:     review.Request.UID,
            Allowed: allowed,
        },
    }

    if !allowed {
        msg := "Liveness probes required:\n" + strings.Join(missing, "\n")
        response.Response.Result = &metav1.Status{Message: msg}
    }

    respBytes, _ := json.Marshal(response)
    w.Header().Set("Content-Type", "application/json")
    w.Write(respBytes)
}

func main() {
    http.HandleFunc("/validate", admitFunc)
    fmt.Println("Starting validating webhook on :8443")
    err := http.ListenAndServeTLS(":8443", "/tls/tls.crt", "/tls/tls.key", nil)
    if err != nil {
        fmt.Println("Failed to start server:", err)
    }
}
EOF

# 2) Write Dockerfile
cat <<'EOF' > Dockerfile
FROM golang:1.24.2-alpine AS builder
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

# 3) Build & push image
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
    --version "${CERT_MANAGER_VERSION}"
fi

# 5a) Ensure namespace exists
echo "Ensuring namespace ${NAMESPACE} exists..."
kubectl get namespace "${NAMESPACE}" \
  || kubectl create namespace "${NAMESPACE}"

# 6) Deploy webhook Service & Deployment
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

# wait for certificate
kubectl -n ${NAMESPACE} wait --for=condition=Ready certificate/${WEBHOOK_NAME}-tls --timeout=60s

# 8) Register ValidatingWebhookConfiguration with automatic CA injection
echo "Registering ValidatingWebhookConfiguration..."
cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: ${WEBHOOK_NAME}
  annotations:
    cert-manager.io/inject-ca-from: ${NAMESPACE}/${WEBHOOK_NAME}-tls
webhooks:
  - name: ${WEBHOOK_NAME}.${NAMESPACE}.svc
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values:
            - webhook-demo
    clientConfig:
      service:
        name: ${WEBHOOK_NAME}
        namespace: ${NAMESPACE}
        path: "/validate"
    rules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        resources: ["deployments"]
        operations: ["CREATE", "UPDATE"]
        scope: Namespaced
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 5
EOF

echo "✅ Validating webhook deployed: enforces liveness probes, skips webhook-demo namespace, and uses cert-manager CA injection."

