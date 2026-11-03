#!/usr/bin/env bash
# Week 8 evidence: Argo CD state + per-environment runtime state vs the values files.
set -uo pipefail
cd "$(dirname "$0")/.."
EV=docs/week8/evidence; mkdir -p "$EV"
PASS=0; FAIL=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then r=PASS; PASS=$((PASS+1)); else r=FAIL; FAIL=$((FAIL+1)); fi
  printf '%-44s %-24s %-24s %s\n' "$1" "$2" "$3" "$r"
}
want() { # env key → value rendered from git (helm template is the oracle)
  helm template shoplite charts/shoplite -n "shop-$1" -f "environments/$1/values.yaml" \
    --set "global.environment=$1" | yq -r "$2" 2>/dev/null | grep -v '^---$'
}

{
  echo "# Argo CD — $(date '+%Y-%m-%d %H:%M:%S %Z')"
  kubectl -n argocd get pods -o wide
  echo
  kubectl -n argocd get appprojects,applicationsets
  echo
  kubectl -n argocd get applications -o custom-columns='APP:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status,HEALTH:.status.health.status,AUTO-SYNC:.spec.syncPolicy.automated,REVISION:.status.sync.revision,PATH:.spec.source.path'
} > "$EV/01-argocd-applications.txt" 2>&1

{
  for env in dev staging prod; do
    echo "════ shop-$env ════"
    kubectl -n "shop-$env" get deploy,sts,pdb,ingress,networkpolicy,pvc
    kubectl -n "shop-$env" get pods -o wide
    echo
  done
} > "$EV/06-environments-runtime.txt" 2>&1

{
  for env in dev staging prod; do
    h="$env.shop.local"
    echo "════ $h ════"
    echo "GET /config/config.json"; curl -s -H "Host: $h" http://127.0.0.1:8080/config/config.json; echo
    echo "GET /api/catalog/products → $(curl -s -o /dev/null -w '%{http_code}' -H "Host: $h" http://127.0.0.1:8080/api/catalog/products)"
    curl -s -H "Host: $h" http://127.0.0.1:8080/api/catalog/products | head -c 220; echo
    pid=$(curl -s -H "Host: $h" http://127.0.0.1:8080/api/catalog/products | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["id"])')
    echo "POST /api/orders {productId:$pid, quantity:1}"
    curl -s -w ' → HTTP %{http_code}' -H "Host: $h" -H 'Content-Type: application/json' -d "{\"productId\":$pid,\"quantity\":1}" http://127.0.0.1:8080/api/orders; echo
    echo
  done
  # Environment isolation: a throw-away pod that carries the orders label (a legitimate DB client
  # inside its own namespace) may reach its own postgres, but not another environment's.
  echo "isolation: probe pod labelled app.kubernetes.io/name=orders in shop-dev"
  kubectl -n shop-dev run netprobe --rm -i --restart=Never --quiet \
    --image=busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec \
    --labels=app.kubernetes.io/name=orders --overrides='{"spec":{"automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"netprobe","image":"busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec","command":["sh","-c","sleep 3; for t in postgres.shop-dev postgres.shop-staging postgres.shop-prod; do if nc -z -w 3 $t.svc.cluster.local 5432; then echo \"$t:5432 REACHABLE\"; else echo \"$t:5432 BLOCKED\"; fi; done"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' 2>&1
} > "$EV/07-traffic-tests.txt" 2>&1

{
  echo "# Design (helm template of git) vs runtime — $(date '+%H:%M:%S')"
  printf '%-44s %-24s %-24s %s\n' CHECK EXPECTED ACTUAL RESULT
  for env in dev staging prod; do
    ns="shop-$env"
    app=$(kubectl -n argocd get application "shoplite-$env" -o jsonpath='{.status.sync.status}/{.status.health.status}')
    check "app shoplite-$env" "Synced/Healthy" "$app"
    check "app shoplite-$env revision = git HEAD" "$(git rev-parse --short=7 HEAD)" \
      "$(kubectl -n argocd get application "shoplite-$env" -o jsonpath='{.status.sync.revision}' | cut -c1-7)"
    for d in catalog orders web; do
      exp=$(want "$env" "select(.kind==\"Deployment\" and .metadata.name==\"$d\") | .spec.replicas")
      act=$(kubectl -n "$ns" get deploy "$d" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')
      check "$ns deploy/$d ready/desired" "$exp/$exp" "$act"
    done
    exp=$(want "$env" 'select(.kind=="Ingress") | .spec.rules[0].host')
    check "$ns ingress host" "$exp" "$(kubectl -n "$ns" get ingress shop -o jsonpath='{.spec.rules[0].host}')"
    exp=$(want "$env" 'select(.kind=="PodDisruptionBudget") | .metadata.name' | wc -l | tr -d ' ')
    check "$ns PodDisruptionBudgets" "$exp" "$(kubectl -n "$ns" get pdb --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    exp=$(want "$env" 'select(.kind=="StatefulSet") | .spec.volumeClaimTemplates[0].spec.resources.requests.storage')
    check "$ns pvc/data-postgres-0" "Bound:$exp" "$(kubectl -n "$ns" get pvc data-postgres-0 -o jsonpath='{.status.phase}:{.status.capacity.storage}')"
    check "$ns PSA enforce" "restricted" "$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
    check "$ns HTTP GET /api/catalog/products" "200" \
      "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $env.shop.local" http://127.0.0.1:8080/api/catalog/products)"
  done
  check "Secret db-credentials tracked by Argo CD" "no" \
    "$(kubectl -n argocd get application shoplite-prod -o jsonpath='{.status.resources[?(@.kind=="Secret")].name}' | grep -q . && echo yes || echo no)"
  echo
  echo "Result: $PASS passed, $FAIL failed"
} 2>&1 | tee "$EV/08-design-vs-runtime.txt"
