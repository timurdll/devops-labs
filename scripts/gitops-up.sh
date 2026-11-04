#!/usr/bin/env bash
# Week 8: install Argo CD into the Week 7 kind cluster and hand the cluster over to git.
# After this script the only way to change ShopLite is a commit (see scripts/gitops-demo.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
CLUSTER=shoplite
VERSION=1.1.0

# 1. Cluster + application images (the Week 7 script is idempotent).
if ! kind get clusters | grep -qx "$CLUSTER"; then
  ./scripts/k8s-up.sh
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null
for svc in catalog orders web; do
  if ! docker exec "$CLUSTER-worker" crictl inspecti -q "docker.io/shoplite/$svc:$VERSION" >/dev/null 2>&1; then
    docker build -q -t "shoplite/$svc:$VERSION" "services/$svc" >/dev/null
    kind load docker-image "shoplite/$svc:$VERSION" --name "$CLUSTER"
  fi
done

# 2. Argo CD control plane. Server-side apply: the ApplicationSet CRD is larger than the
#    262 KB last-applied annotation that client-side apply would need.
kubectl apply --server-side --force-conflicts -k gitops/argocd >/dev/null
for d in argocd-server argocd-repo-server argocd-applicationset-controller argocd-redis argocd-dex-server; do
  kubectl -n argocd rollout status "deploy/$d" --timeout=300s
done
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
# The application controller and repo server read argocd-cm / argocd-cmd-params-cm at start.
kubectl -n argocd rollout restart deploy/argocd-server deploy/argocd-repo-server statefulset/argocd-application-controller >/dev/null
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# 3. Environment namespaces + database credentials. The namespaces are the same objects the
#    platform Application manages (Argo CD adopts them); the Secrets are the only state that is
#    deliberately NOT in git (ADR-W8-03).
kubectl apply --server-side -f k8s/platform/environments.yaml >/dev/null
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }
for env in dev staging prod; do
  f="environments/$env/db.env"
  if [ ! -f "$f" ]; then
    (umask 077; printf 'POSTGRES_PASSWORD=%s\nCATALOG_DB_PASSWORD=%s\nORDERS_DB_PASSWORD=%s\n' "$(gen)" "$(gen)" "$(gen)" > "$f")
    echo "generated $f"
  fi
  kubectl -n "shop-$env" create secret generic db-credentials --from-env-file="$f" \
    --dry-run=client -o yaml | kubectl apply --server-side -f - >/dev/null
done

# 4. Bootstrap: the root Application (app of apps). Everything else is pulled from git.
kubectl apply -f gitops/bootstrap/root.yaml
echo "waiting for the environment Applications to be generated…"
for env in dev staging prod; do
  until kubectl -n argocd get application "shoplite-$env" >/dev/null 2>&1; do sleep 2; done
done
for env in dev staging; do
  kubectl -n argocd wait "application/shoplite-$env" --timeout=600s \
    --for=jsonpath='{.status.health.status}'=Healthy
done
kubectl -n argocd get applications -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'
echo
echo "prod is not auto-synced. Approve the first release with:  ./scripts/gitops-sync-prod.sh"
echo "Argo CD UI: kubectl -n argocd port-forward svc/argocd-server 8081:80  →  http://localhost:8081"
echo "  user admin, password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
