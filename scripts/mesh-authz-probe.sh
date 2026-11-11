#!/usr/bin/env bash
# Week 10 — labels are not identity. NetworkPolicy trusts pod labels; AuthorizationPolicy trusts
# the SPIFFE ID in the peer's mTLS certificate, which comes from the pod's ServiceAccount.
#
#   impostor  pod labelled app.kubernetes.io/name=orders (passes NetworkPolicy allow-to-catalog),
#             with a sidecar, but ServiceAccount "default" → spiffe://cluster.local/ns/<ns>/sa/default
#             Its readiness probe always fails, so it never joins the orders Service's endpoints.
#   orders    an ephemeral curl container in a real orders pod (normal UID → through the orders
#             sidecar) → spiffe://cluster.local/ns/<ns>/sa/orders
# Expected under phase 2: impostor → 403 "RBAC: access denied", orders → 200.
# Usage: scripts/mesh-authz-probe.sh <env>
set -euo pipefail
env=${1:?usage: $0 <dev|staging|prod>}; ns=shop-$env
CURL_IMAGE=curlimages/curl:8.17.0@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40
target=http://catalog.$ns.svc.cluster.local/api/catalog/products
export PATH="${ISTIOCTL_DIR:-}:$PATH"

echo "# $(date -u +%FT%TZ)  namespace $ns  target $target"
echo; echo "## AuthorizationPolicies"; kubectl -n "$ns" get authorizationpolicy
echo; echo "## 1. impostor: label app.kubernetes.io/name=orders, ServiceAccount default, with sidecar"
kubectl -n "$ns" delete pod authz-impostor --ignore-not-found --wait >/dev/null
kubectl -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: authz-impostor
  labels:
    app.kubernetes.io/name: orders # what NetworkPolicy allow-to-catalog looks at
    sidecar.istio.io/inject: "true"
spec:
  serviceAccountName: default
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    runAsGroup: 101
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: probe
      image: $CURL_IMAGE
      command: ["sleep", "600"]
      readinessProbe: # never Ready → never an endpoint of the orders Service
        exec: { command: ["false"] }
        periodSeconds: 5
      resources:
        requests: { cpu: 5m, memory: 8Mi }
        limits: { cpu: 100m, memory: 32Mi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
EOF
kubectl -n "$ns" wait pod authz-impostor --for=jsonpath='{.status.containerStatuses[?(@.name=="probe")].started}'=true --timeout=120s >/dev/null
echo "  containers: $(kubectl -n "$ns" get pod authz-impostor -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}')"
echo "  orders EndpointSlice entry: $(kubectl -n "$ns" get endpointslice -l kubernetes.io/service-name=orders -o jsonpath='{range .items[*].endpoints[?(@.targetRef.name=="authz-impostor")]}ready={.conditions.ready}{end}') (Envoy and kube-proxy route to ready endpoints only)"
# SAN of the workload certificate the sidecar received from istiod (retried: SDS needs a moment).
san() { istioctl proxy-config secret "$1" -o json 2>/dev/null | python3 -c '
import base64, json, re, subprocess, sys
d = json.load(sys.stdin)
c = [s for s in d.get("dynamicActiveSecrets", []) if s["name"] == "default"][0]["secret"]["tlsCertificate"]["certificateChain"]["inlineBytes"]
txt = subprocess.run(["openssl", "x509", "-noout", "-text"], input=base64.b64decode(c), capture_output=True).stdout.decode()
print(re.search(r"URI:(\S+)", txt)[1])'; }
for _ in $(seq 20); do id=$(san "authz-impostor.$ns") && break; sleep 1; done
echo "  identity (certificate SAN): ${id:-unknown}"
kubectl -n "$ns" exec authz-impostor -c probe -- curl -sS -m 5 -w '\n  → HTTP %{http_code}\n' "$target" | sed 's/^/  body: /; s/^  body:   →/  →/'

echo; echo "## 2. real orders identity (ephemeral container in an orders pod, through its sidecar)"
orders=$(kubectl -n "$ns" get pod -l app.kubernetes.io/name=orders,version=v1 -o jsonpath='{.items[0].metadata.name}')
dbg=authz-$(date +%s)
spec=$(mktemp); trap 'rm -f "$spec"' EXIT
echo '{"securityContext":{"runAsUser":65532,"runAsGroup":65532,"runAsNonRoot":true,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}' > "$spec"
kubectl -n "$ns" debug "$orders" -q --container="$dbg" --image="$CURL_IMAGE" --profile=restricted --custom="$spec" -- \
  curl -sS -m 5 -o /dev/null -w "  $orders (sa/orders) → HTTP %{http_code}\n" "$target" >/dev/null
kubectl -n "$ns" wait pod "$orders" --for=jsonpath="{.status.ephemeralContainerStatuses[?(@.name=='$dbg')].state.terminated.reason}"=Completed --timeout=60s >/dev/null 2>&1 || true
kubectl -n "$ns" logs "$orders" -c "$dbg"

echo; echo "## 3. the decision inside catalog's sidecar (istioctl x authz check)"
catalog=$(kubectl -n "$ns" get pod -l app.kubernetes.io/name=catalog,version=v1 -o jsonpath='{.items[0].metadata.name}')
istioctl x authz check "$catalog.$ns" 2>&1 | sed 's/^/  /'

echo; echo "## 4. RBAC filter counters in the catalog sidecar"
kubectl -n "$ns" exec "$catalog" -c istio-proxy -- pilot-agent request GET 'stats?filter=rbac' 2>/dev/null | grep -E "allowed|denied" | sed 's/^/  /'

kubectl -n "$ns" delete pod authz-impostor --wait=false >/dev/null
echo; echo "# impostor pod deleted"
