#!/usr/bin/env bash
# Week 8 evidence: three GitOps scenarios, each recorded as a timeline of Application states.
#   A  commit → dev auto-sync        (git is the trigger; nobody runs kubectl)
#   B  drift  → staging self-heal    (a live edit is reverted to the git state)
#   C  commit → prod waits           (OutOfSync until an operator approves the sync)
# Requires: scripts/gitops-up.sh done, push access to the tracked branch.
set -euo pipefail
cd "$(dirname "$0")/.."
EV=docs/week8/evidence; mkdir -p "$EV"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
curl_cfg() { curl -s -H "Host: $1.shop.local" http://127.0.0.1:8080/config/config.json; }
push() { git add "$@"; git commit -q -m "$MSG [skip ci]"; git push -q origin "$BRANCH"; git rev-parse --short=7 HEAD; }

# ── A · commit to dev ──────────────────────────────────────────────────────────────────────────
{
  echo "# Scenario A — change environments/dev/values.yaml, push, let Argo CD reconcile"
  echo "## before"; curl_cfg dev; echo
  kubectl -n shop-dev get deploy catalog -o custom-columns='DEPLOY:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas'
  python3 - <<'PY'
import re
p = "environments/dev/values.yaml"
s = open(p).read()
s = s.replace("  catalog:\n    replicas: 1\n", "  catalog:\n    replicas: 2\n", 1)
s = re.sub(r'banner: ".*"', 'banner: "dev: deployed by Argo CD from git commit (Week 8 demo)"', s, count=1)
open(p, "w").write(s)
PY
  echo "## git diff"; git --no-pager diff environments/dev/values.yaml
  MSG="demo(dev): catalog 1→2 replicas, new banner"
  echo "## push at $(date '+%H:%M:%S')"; SHA=$(push environments/dev/values.yaml); echo "commit $SHA"
  echo "## Application timeline"
  ./scripts/gitops-watch.sh shoplite-dev 300 "Synced Healthy $SHA"
  echo "## after"; curl_cfg dev; echo
  kubectl -n shop-dev get deploy catalog -o custom-columns='DEPLOY:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas'
  kubectl -n shop-dev get pods -l app.kubernetes.io/name=catalog -o wide
} 2>&1 | tee "$EV/03-scenario-a-commit-to-dev.txt"

# ── B · drift in staging ───────────────────────────────────────────────────────────────────────
{
  echo "# Scenario B — manual drift: kubectl scale deploy/orders --replicas=5 in shop-staging"
  SHA=$(kubectl -n argocd get application shoplite-staging -o jsonpath='{.status.sync.revision}' | cut -c1-7)
  echo "## drift at $(date '+%H:%M:%S')"
  kubectl -n shop-staging scale deploy/orders --replicas=5
  ./scripts/gitops-watch.sh shoplite-staging 5
  echo "## Application timeline (self-heal)"
  ./scripts/gitops-watch.sh shoplite-staging 180 "Synced Healthy $SHA"
  kubectl -n shop-staging get deploy orders -o custom-columns='DEPLOY:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas'
  echo "## ReplicaSet events"
  kubectl -n shop-staging get events --field-selector involvedObject.kind=ReplicaSet --sort-by=.lastTimestamp | grep orders | tail -6
} 2>&1 | tee "$EV/04-scenario-b-drift-self-heal.txt"

# ── C · prod manual gate ───────────────────────────────────────────────────────────────────────
{
  echo "# Scenario C — change environments/prod/values.yaml; prod must wait for approval"
  python3 - <<'PY'
p = "environments/prod/values.yaml"
s = open(p).read()
s = s.replace("      shopName: ShopLite\n", '      shopName: ShopLite\n      banner: "Release 2026.11 approved for production"\n', 1)
open(p, "w").write(s)
PY
  echo "## git diff"; git --no-pager diff environments/prod/values.yaml
  MSG="demo(prod): release banner"
  echo "## push at $(date '+%H:%M:%S')"; SHA=$(push environments/prod/values.yaml); echo "commit $SHA"
  echo "## Application timeline without approval (120 s)"
  ./scripts/gitops-watch.sh shoplite-prod 120
  echo "## prod still serves the old config:"; curl_cfg prod; echo
  echo "## operator approves at $(date '+%H:%M:%S')"
  ./scripts/gitops-sync-prod.sh --yes 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | tail -40
  ./scripts/gitops-watch.sh shoplite-prod 120 "Synced Healthy $SHA"
  echo "## after"; curl_cfg prod; echo
} 2>&1 | tee "$EV/05-scenario-c-prod-manual-gate.txt"
