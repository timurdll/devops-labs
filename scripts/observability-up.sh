#!/usr/bin/env bash
# Week 9: hand the observability stack to Argo CD (on top of the Week 8 GitOps cluster).
# Git holds every manifest; this script only does what must NOT be in git (the Grafana admin
# Secret) and points the root Application at the Week 9 branch.
set -euo pipefail
cd "$(dirname "$0")/.."
CLUSTER=shoplite
BRANCH=$(git rev-parse --abbrev-ref HEAD)
kubectl config use-context "kind-$CLUSTER" >/dev/null

# 1. Third-party images: pre-load into the kind nodes (kind cannot pull multi-arch digests by
#    itself through `kind load docker-image`, so save the node's platform to an archive first).
for img in $(grep -ho 'image: [^ ]*@sha256:[a-f0-9]*' k8s/observability/*.yaml | awk '{print $2}'); do
  ref=${img%@*}
  if ! docker exec "$CLUSTER-worker" crictl inspecti -q "docker.io/$ref" >/dev/null 2>&1; then
    docker pull -q --platform linux/arm64 "$img" >/dev/null
    tar=$(mktemp -t obs-image).tar
    docker save --platform linux/arm64 "$ref" -o "$tar"
    kind load image-archive "$tar" --name "$CLUSTER" && rm -f "$tar"
  fi
done

# 2. Grafana admin credentials: random, git-ignored, never rendered by Argo CD (ADR-W8-03 pattern).
kubectl apply --server-side -f k8s/observability/namespace.yaml >/dev/null
f=k8s/observability/grafana-admin.env
if [ ! -f "$f" ]; then
  (umask 077; printf 'admin-user=admin\nadmin-password=%s\n' "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)" > "$f")
  echo "generated $f"
fi
kubectl -n observability create secret generic grafana-admin --from-env-file="$f" \
  --dry-run=client -o yaml | kubectl apply --server-side -f - >/dev/null

# 3. Root Application → this branch (it then picks up gitops/apps/observability.yaml).
git ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null || { echo "push $BRANCH first" >&2; exit 1; }
kubectl apply -f gitops/bootstrap/root.yaml >/dev/null
until kubectl -n argocd get application observability >/dev/null 2>&1; do sleep 2; done
for app in observability platform shoplite-dev shoplite-staging; do
  kubectl -n argocd wait "application/$app" --timeout=600s --for=jsonpath='{.status.sync.status}'=Synced
  kubectl -n argocd wait "application/$app" --timeout=600s --for=jsonpath='{.status.health.status}'=Healthy
done
kubectl -n argocd get applications -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'
echo
echo "prod (manual): ./scripts/gitops-sync-prod.sh"
echo "Grafana: kubectl -n observability port-forward svc/grafana 3000  →  http://localhost:3000 (user/password in $f)"
echo "Jaeger:  kubectl -n observability port-forward svc/jaeger 16686  →  http://localhost:16686"
