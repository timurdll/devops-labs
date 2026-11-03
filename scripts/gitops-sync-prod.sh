#!/usr/bin/env bash
# The manual approval gate of prod: show what would change, then sync shoplite-prod.
# Uses `argocd --core` (talks to the Kubernetes API with your kubeconfig, no Argo CD login).
set -euo pipefail
KUBECONFIG_TMP=$(mktemp); trap 'rm -f "$KUBECONFIG_TMP"' EXIT
kind get kubeconfig --name shoplite > "$KUBECONFIG_TMP"
export KUBECONFIG=$KUBECONFIG_TMP
kubectl config set-context --current --namespace=argocd >/dev/null

argocd app diff shoplite-prod --core --refresh || true   # exit 1 = there are differences
if [ "${1:-}" != "--yes" ]; then
  read -r -p "Sync shoplite-prod to $(kubectl get application shoplite-prod -o jsonpath='{.status.sync.revision}' | cut -c1-7)? [y/N] " ok
  [ "$ok" = y ] || { echo "aborted"; exit 1; }
fi
argocd app sync shoplite-prod --core --timeout 600
argocd app wait shoplite-prod --core --health --timeout 600
