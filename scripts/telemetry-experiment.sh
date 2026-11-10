#!/usr/bin/env bash
# Week 9 experiment: steady load on dev/staging/prod, then a dependency outage in prod
# (catalog scaled to 0 — prod has no self-heal, so Argo CD leaves the drift alone; OutOfSync).
# Expected telemetry, checked afterwards in Grafana / Prometheus / Jaeger:
#   metrics: orders POST /api/orders → 502, Traefik → 503 for /api/catalog/*, error ratio > 5 %
#   alerts:  ShopLiteHighErrorRate pending → firing after 1 min
#   traces:  orders span ERROR + undici client span with ECONNREFUSED, no catalog span
# Usage: telemetry-experiment.sh [baseline=120] [outage=120] [recovery=120]
set -euo pipefail
cd "$(dirname "$0")/.."
BASE=${1:-120}; OUTAGE=${2:-120}; RECOVER=${3:-120}
TOTAL=$((BASE + OUTAGE + RECOVER))
ts() { date -u +%FT%TZ; }
TMP=$(mktemp -d)

echo "$(ts) load start: dev, staging, prod for ${TOTAL}s"
./scripts/telemetry-load.sh dev "$TOTAL" 2 > "$TMP/dev" &
./scripts/telemetry-load.sh staging "$TOTAL" 2 > "$TMP/staging" &
./scripts/telemetry-load.sh prod "$TOTAL" 3 > "$TMP/prod" &

sleep "$BASE"
replicas=$(kubectl -n shop-prod get deploy catalog -o jsonpath='{.spec.replicas}')
echo "$(ts) FAULT: kubectl -n shop-prod scale deploy/catalog --replicas=0 (was $replicas)"
kubectl -n shop-prod scale deploy/catalog --replicas=0 >/dev/null
sleep "$OUTAGE"
echo "$(ts) RECOVER: kubectl -n shop-prod scale deploy/catalog --replicas=$replicas"
kubectl -n shop-prod scale deploy/catalog --replicas="$replicas" >/dev/null
kubectl -n shop-prod rollout status deploy/catalog --timeout=120s >/dev/null
echo "$(ts) catalog ready again"
wait
echo "$(ts) load done"
for env in dev staging prod; do echo "--- $env"; cat "$TMP/$env"; done
rm -rf "$TMP"
