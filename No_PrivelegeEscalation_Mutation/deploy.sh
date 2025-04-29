#!/bin/bash
set -e

# Configuration
DOCKERHUB_USERNAME="creativsrwr"
WEBHOOK_NAME="disable-privilege-escalation-mutator"
NAMESPACE="webhook-demo"
IMAGE="${DOCKERHUB_USERNAME}/${WEBHOOK_NAME}:latest"
CERT_MANAGER_VERSION="v1.17.0"

# 1) Write main.go
cat <<'EOF' > main.go
package main

import (
    "encoding/json"
    "fmt"
    "io/ioutil"
    "net/http"

    admissionv1 "k8s.io/api/admission/v1"
    corev1      "k8s.io/api/core/v1"
    appsv1      "k8s.io/api/apps/v1"
)

func mutate(w http.ResponseWriter, r *http.Request) {
    var review admissionv1.AdmissionReview
    body, _ := ioutil.ReadAll(r.Body)
    _ = json.Unmarshal(body, &review)

    var patches []map[string]interface{}

    // Helper to emit patches for a container slice
    handleContainers := func(containers []corev1.Container, basePath string) {
        for i, c := range containers {
            sc := c.SecurityContext
            pathSC := fmt.Sprintf("%s/%d/securityContext", basePath, i)
            pathAP := fmt.Sprintf("%s/%d/securityContext/allowPrivilegeEscalation", basePath, i)

            if sc == nil {
                // container.SecurityContext == nil  → add entire object
                patches = append(patches, map[string]interface{}{
                    "op":    "add",
                    "path":  pathSC,
                    "value": map[string]bool{"allowPrivilegeEscalation": false},
                })
            } else if sc.AllowPrivilegeEscalation == nil || *sc.AllowPrivilegeEscalation {
                // object exists but field missing or true → add/replace field
                patches = append(patches, map[string]interface{}{
                    "op":    "add",
                    "path":  pathAP,
                    "value": false,
                })
            }
        }
    }

    // Dispatch on Pod vs Deployment
    switch review.Request.Kind.Kind {
    case "Pod":
        pod := corev1.Pod{}
        _ = json.Unmarshal(review.Request.Object.Raw, &pod)
        handleContainers(pod.Spec.Containers, "/spec/containers")
        handleContainers(pod.Spec.InitContainers, "/spec/initContainers")

    case "Deployment":
        dep := appsv1.Deployment{}
        _ = json.Unmarshal(review.Request.Object.Raw, &dep)
        // PodTemplate sits under spec.template.spec
        handleContainers(dep.Spec.Template.Spec.Containers, "/spec/template/spec/containers")
        handleContainers(dep.Spec.Template.Spec.InitContainers, "/spec/template/spec/initContainers")
    }

    // Build the AdmissionResponse
    patchBytes, _ := json.Marshal(patches)
    pt := admissionv1.PatchTypeJSONPatch
    resp := admissionv1.AdmissionResponse{
        UID:       review.Request.UID,
        Allowed:   true,
        Patch:     patchBytes,
        PatchType: &pt,
    }
    review.Response = &resp

    respBytes, _ := json.Marshal(review)
    w.Header().Set("Content-Type", "application/json")
    w.Write(respBytes)
}

func main() {
    http.HandleFunc("/mutate", mutate)
    fmt.Println("Starting mutating webhook on :8443")
    if err := http.ListenAndServeTLS(":8443", "/tls/tls.crt", "/tls/tls.key", nil); err != nil {
        fmt.Println("Failed to start server:", err)
    }
}
EOF

# ---------- 2) Write Dockerfile ----------
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

# ---------- 3) Build & push image ----------
echo "Building and pushing ${IMAGE}..."
docker build -t "${IMAGE}" .
docker push "${IMAGE}"

# ---------- 4) Ensure kind cluster ----------
if ! kind get clusters | grep -q '^kind$'; then
  kind create cluster --name kind
fi
kubectl cluster-info --context kind-kind

# ---------- 5) Install cert-manager ----------
if ! kubectl get deploy cert-manager -n cert-manager &>/dev/null; then
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version "${CERT_MANAGER_VERSION}" \
    --set crds.enabled=true
fi
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s

# ---------- 6) Deploy Service & Deployment ----------
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
          ports:
            - containerPort: 8443
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

# ---------- 7) Create Issuer & Certificate ----------
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

# ---------- 8) Register MutatingWebhookConfiguration ----------
CA_BUNDLE=$(kubectl get secret ${WEBHOOK_NAME}-tls -n ${NAMESPACE} \
  -o jsonpath='{.data.ca\.crt}')
cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: ${WEBHOOK_NAME}
  annotations:
    cert-manager.io/inject-ca-from: ${NAMESPACE}/${WEBHOOK_NAME}-tls
webhooks:
  - name: ${WEBHOOK_NAME}.webhook-demo.svc
    clientConfig:
      service:
        name: ${WEBHOOK_NAME}
        namespace: ${NAMESPACE}
        path: "/mutate"
      caBundle: "${CA_BUNDLE}"
    rules:
      - apiGroups: ["apps",""]
        apiVersions: ["v1"]
        resources: ["deployments","pods"]
        operations: ["CREATE","UPDATE"]
        scope: "Namespaced"
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values:
            - "${NAMESPACE}"
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 5
EOF

echo "✅ Mutating webhook deployed: Privilege escalation now disallowed across all namespaces except ${NAMESPACE}."

