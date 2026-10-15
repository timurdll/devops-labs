#!/usr/bin/env bash
# Week 7: create the kind cluster (if needed), build + load images, generate secrets, deploy.
set -euo pipefail
cd "$(dirname "$0")/.."
CLUSTER=shoplite
VERSION=1.0.1

if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --config kind/cluster.yaml --wait 120s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

# Docker Hub pulls go through Google's public mirror first, Docker Hub second.
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" sh -c 'mkdir -p /etc/containerd/certs.d/docker.io && cat > /etc/containerd/certs.d/docker.io/hosts.toml' <<'TOML'
server = "https://registry-1.docker.io"

[host."https://mirror.gcr.io"]
  capabilities = ["pull", "resolve"]
TOML
done

# Secret values never live in git: generate them once into the git-ignored env file.
SECRET_FILE=k8s/shop/secrets/db.env
if [ ! -f "$SECRET_FILE" ] || grep -q 'replace-me' "$SECRET_FILE"; then
  gen() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }
  umask 077
  printf 'POSTGRES_PASSWORD=%s\nCATALOG_DB_PASSWORD=%s\nORDERS_DB_PASSWORD=%s\n' "$(gen)" "$(gen)" "$(gen)" > "$SECRET_FILE"
  echo "generated $SECRET_FILE"
fi

for svc in catalog orders web; do
  docker build -q -t "shoplite/$svc:$VERSION" "services/$svc" >/dev/null
  kind load docker-image "shoplite/$svc:$VERSION" --name "$CLUSTER"
done

kubectl apply -k k8s/
kubectl -n ingress-traefik rollout status deploy/traefik --timeout=180s
kubectl -n shop rollout status statefulset/postgres --timeout=300s
for d in catalog orders web; do kubectl -n shop rollout status "deploy/$d" --timeout=180s; done
echo "ShopLite is up: curl -H 'Host: shop.local' http://127.0.0.1:8080/  (or add '127.0.0.1 shop.local' to /etc/hosts)"
