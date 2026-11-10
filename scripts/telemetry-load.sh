#!/usr/bin/env bash
# Week 9: synthetic user traffic through the ingress (Traefik → web/catalog/orders) so that the
# RED panels and traces have data. Mix per iteration: 3 catalog reads, 1 product miss (404), 1 order list,
# 1 order (201), 1 invalid order (422), 1 order over stock (409), 1 unknown API route (404),
# 1 page load (web).
# Each worker pauses PAUSE seconds between requests (default 0.1 → ≈ 8 req/s per worker), so the
# load looks like steady user traffic instead of a benchmark. A failed request is counted as 000
# and never stops the worker.
# Usage: telemetry-load.sh <env> [seconds=120] [workers=4]
set -euo pipefail
ENV=${1:?usage: $0 <dev|staging|prod> [seconds] [workers]}
SECONDS_TOTAL=${2:-120}
WORKERS=${3:-4}
PAUSE=${PAUSE:-0.1}
HOST="$ENV.shop.local"
BASE=http://127.0.0.1:8080
OUT=$(mktemp -d)

worker() {
  local end=$((SECONDS + SECONDS_TOTAL))
  while [ $SECONDS -lt $end ]; do
    for path in /api/catalog/products /api/catalog/products/1 /api/catalog/products/2 \
                /api/catalog/products/999 /api/orders /api/catalog/unknown /; do
      curl -s -o /dev/null -w '%{http_code}\n' -H "Host: $HOST" "$BASE$path" || true
      sleep "$PAUSE"
    done
    for body in '{"productId":1,"quantity":1}' '{"productId":1,"quantity":0}' '{"productId":1,"quantity":99}'; do
      curl -s -o /dev/null -w '%{http_code}\n' -H "Host: $HOST" -H 'Content-Type: application/json' \
        -d "$body" "$BASE/api/orders" || true
      sleep "$PAUSE"
    done
  done
}

for i in $(seq "$WORKERS"); do worker > "$OUT/$i" & done
wait
total=$(cat "$OUT"/* | wc -l | tr -d ' ')
echo "env=$ENV duration=${SECONDS_TOTAL}s workers=$WORKERS requests=$total (~$((total / SECONDS_TOTAL)) req/s)"
echo "status codes:"; cat "$OUT"/* | sort | uniq -c | sort -rn
rm -rf "$OUT"
