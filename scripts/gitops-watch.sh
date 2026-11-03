#!/usr/bin/env bash
# Print every state transition of an Argo CD Application with a timestamp (the FSM, observed).
# usage: gitops-watch.sh <app> <max-seconds> [stop-when: "Synced Healthy <sha7>"]
set -uo pipefail
app=$1; max=$2; stop=${3:-}
t0=$(date +%s); last=""
while :; do
  s=$(kubectl -n argocd get application "$app" -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase} {.status.sync.revision}' 2>/dev/null)
  read -r sync health phase rev <<<"$s"
  [ -n "${rev:-}" ] || { rev=$phase; phase=-; }   # no operation yet
  cur="sync=$sync health=$health operation=${phase:--} revision=${rev:0:7}"
  if [ "$cur" != "$last" ]; then
    printf '%s  +%3ss  %-14s %s\n' "$(date '+%H:%M:%S')" "$(( $(date +%s) - t0 ))" "$app" "$cur"
    last=$cur
  fi
  [ -n "$stop" ] && [ "$sync $health ${rev:0:7}" = "$stop" ] && break
  [ $(( $(date +%s) - t0 )) -ge "$max" ] && { echo "(stopped after ${max}s)"; break; }
  sleep 1
done
