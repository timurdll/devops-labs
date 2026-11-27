#!/usr/bin/env bash
# Week 11: run the chaos experiments E1–E3 against shop-staging, one after another, each under
# 10 orders/s (scripts/chaos-experiment.py), and print the hypothesis verdicts.
# Needs: kubectl context of the kind cluster, Prometheus port-forward on :9090.
set -euo pipefail
cd "$(dirname "$0")/.."
EV=docs/week11/evidence
run() { local f=$1 out=$2; shift 2
  python3 -u scripts/chaos-experiment.py "k8s/chaos/experiments/$f" --out "$EV/$out" "$@" > /dev/null
  echo "== $out"; sed -n '5,9p' "$EV/$out/summary.txt"; grep -E "^  (PASS|FAIL)|^RESULT" "$EV/$out/summary.txt"; echo
  sleep 20 # let breakers settle and Prometheus scrape before the next experiment
}
run e1-catalog-latency.yaml   e1-catalog-latency
run e2-catalog-partition.yaml e2-catalog-partition --chaos 90 --chaos-ids 4
run e3-catalog-pod-kill.yaml  e3-catalog-pod-kill  --chaos 60 --recovery 30
