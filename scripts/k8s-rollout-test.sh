#!/usr/bin/env bash
# Zero-downtime check: restart every stateless workload one by one while a client loop
# keeps calling the shop through the Ingress; afterwards print the HTTP status histogram.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-docs/week7/evidence/10b-rolling-update-after-fix.txt}
CODES=$(mktemp)

(while true; do
  for p in / /api/catalog/products /api/orders; do
    curl -s -o /dev/null -m 3 -w '%{http_code}\n' -H 'Host: shop.local' "http://127.0.0.1:8080$p"
  done
done > "$CODES") &
LOOP=$!

{
  echo "# Rolling restart under load — $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo "# Pods: preStop sleep 5s; Traefik x2 with requestAcceptGraceTimeout=5s; maxSurge=1/maxUnavailable=0."
  sleep 2
  for target in "ingress-traefik deploy/traefik" "shop deploy/catalog" "shop deploy/orders" "shop deploy/web"; do
    read -r ns obj <<< "$target"
    echo; echo "\$ kubectl -n $ns rollout restart $obj && kubectl -n $ns rollout status $obj"
    kubectl -n "$ns" rollout restart "$obj"
    kubectl -n "$ns" rollout status "$obj" --timeout=180s | tail -1
  done
  sleep 8
  kill "$LOOP"; wait "$LOOP" 2>/dev/null
  echo; echo "# HTTP status codes seen by the client during the four rollouts"
  sort "$CODES" | uniq -c
  echo; echo "Total requests: $(wc -l < "$CODES" | tr -d ' '), non-2xx: $(grep -vc '^2' "$CODES")"
} 2>&1 | tee "$OUT"
rm -f "$CODES"
