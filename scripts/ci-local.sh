#!/usr/bin/env bash
# Runs the quality gates of .github/workflows/ci.yml on a workstation, using the same
# pinned tool images, and stores the evidence in docs/week6/evidence/.
# Requirements: Docker, Node.js 24, git, kubectl.
set -uo pipefail
cd "$(dirname "$0")/.."

EVIDENCE=docs/week6/evidence
mkdir -p "$EVIDENCE/trivy"

# Tool images are read from ci.yml so local runs and CI can never drift apart.
ci_env() { grep -E "^  $1:" .github/workflows/ci.yml | awk '{print $2}'; }
GITLEAKS_IMAGE=$(ci_env GITLEAKS_IMAGE)
SEMGREP_IMAGE=$(ci_env SEMGREP_IMAGE)
HADOLINT_IMAGE=$(ci_env HADOLINT_IMAGE)
KUBECONFORM_IMAGE=$(ci_env KUBECONFORM_IMAGE)
ACTIONLINT_IMAGE=$(ci_env ACTIONLINT_IMAGE)
TRIVY_IMAGE=aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa
SEVERITY=HIGH,CRITICAL
K8S_VERSION=${K8S_VERSION:-1.37.0}

trivy() {
  docker run --rm -e TRIVY_NO_PROGRESS=true -e TRIVY_SKIP_VERSION_CHECK=true \
    -v /var/run/docker.sock:/var/run/docker.sock -v shoplite-trivy-cache:/root/.cache/trivy -v "$PWD:/src" -w /src "$TRIVY_IMAGE" "$@"
}

RESULTS=()
gate() {
  local name=$1; shift
  printf '\n━━━ %s ━━━\n' "$name"
  local start=$SECONDS
  if "$@"; then
    RESULTS+=("PASS  $name  ($((SECONDS - start))s)")
  else
    RESULTS+=("FAIL  $name  ($((SECONDS - start))s)")
  fi
}

g1_secrets() {
  git add -A >/dev/null # gitleaks inspects the staged snapshot (CI scans the full history)
  docker run --rm -v "$PWD:/repo" -w /repo "$GITLEAKS_IMAGE" \
    git /repo --staged --redact --verbose --exit-code 1 --no-banner
}

g2_lint_code() {
  local rc=0
  for s in catalog orders; do
    echo "• eslint services/$s"
    (cd "services/$s" && npm ci --ignore-scripts --no-audit --no-fund --silent && npm run -s lint) || rc=1
  done
  return $rc
}

g2_lint_infra() {
  local rc=0
  for f in services/*/Dockerfile; do
    echo "• hadolint $f"
    docker run --rm -i "$HADOLINT_IMAGE" hadolint --failure-threshold warning - < "$f" || rc=1
  done
  echo "• kubeconform (Kubernetes $K8S_VERSION, strict)"
  [ -f k8s/shop/secrets/db.env ] || cp k8s/shop/secrets/db.env.example k8s/shop/secrets/db.env
  kubectl kustomize k8s/ > "$EVIDENCE/rendered-k8s.yaml"
  docker run --rm -v "$PWD/$EVIDENCE:/work" "$KUBECONFORM_IMAGE" \
    -strict -summary -kubernetes-version "$K8S_VERSION" /work/rendered-k8s.yaml || rc=1
  # never keep Secret values in the evidence folder
  python3 - "$EVIDENCE/rendered-k8s.yaml" <<'PY'
import re, sys
path = sys.argv[1]
docs = open(path).read().split("\n---\n")
docs = [re.sub(r"(?m)^(  [A-Z_]+: ).*$", r"\1<redacted>", d) if "kind: Secret" in d else d for d in docs]
open(path, "w").write("\n---\n".join(docs))
PY
  echo "• actionlint .github/workflows/ci.yml"
  docker run --rm -v "$PWD:/repo" -w /repo "$ACTIONLINT_IMAGE" -color || rc=1
  return $rc
}

g3_tests() {
  local rc=0
  for s in catalog orders; do
    echo "• node --test services/$s"
    (cd "services/$s" && npm test) || rc=1
  done
  return $rc
}

g4_sast() {
  docker run --rm -v "$PWD:/src" -w /src "$SEMGREP_IMAGE" semgrep scan \
    --config p/javascript --config p/nodejs --config p/secrets \
    --config p/dockerfile --config p/kubernetes --config p/github-actions --config .semgrep/ \
    --severity ERROR --severity WARNING \
    --exclude node_modules --metrics off --error --text
}

g5_deps() {
  local rc=0
  for s in catalog orders; do
    echo "• npm audit services/$s"
    (cd "services/$s" && npm audit signatures && npm audit --omit=dev --audit-level=high) || rc=1
  done
  return $rc
}

g6_build_and_scan() {
  local rc=0
  for s in catalog orders web; do
    echo "• docker build shoplite/$s:1.0.1"
    docker build -q -t "shoplite/$s:1.0.1" "services/$s" || { rc=1; continue; }
    echo "• trivy gate shoplite/$s:1.0.1 (fixable $SEVERITY ⇒ fail)"
    trivy image --scanners vuln,secret --severity "$SEVERITY" --ignore-unfixed --exit-code 1 \
      --format table --output "/src/$EVIDENCE/trivy/$s-gate.txt" "shoplite/$s:1.0.1"
    local gate_rc=$?
    cat "$EVIDENCE/trivy/$s-gate.txt"
    [ $gate_rc -eq 0 ] || rc=1
    # full report (all severities, informational) + SBOM
    trivy image --skip-db-update --scanners vuln --format json \
      --output "/src/$EVIDENCE/trivy/$s-full.json" "shoplite/$s:1.0.1" >/dev/null 2>&1
    trivy image --skip-db-update --scanners vuln --format table \
      --output "/src/$EVIDENCE/trivy/$s-full.txt" "shoplite/$s:1.0.1" >/dev/null 2>&1
    trivy image --skip-db-update --format cyclonedx \
      --output "/src/$EVIDENCE/trivy/$s-sbom.cdx.json" "shoplite/$s:1.0.1" >/dev/null 2>&1
  done
  return $rc
}

g7_iac() {
  trivy config --severity "$SEVERITY" --exit-code 1 --ignorefile .trivyignore.yaml --skip-dirs docs \
    --skip-dirs services/catalog/node_modules --skip-dirs services/orders/node_modules --format table .
}

{
  echo "ShopLite local CI run — $(date -u '+%Y-%m-%d %H:%M:%S UTC') — $(uname -sm)"
  gate "G1 secret scan (gitleaks)"            g1_secrets
  gate "G2 lint code (eslint)"                g2_lint_code
  gate "G2 lint infra (hadolint/kubeconform/actionlint)" g2_lint_infra
  gate "G3 unit tests + coverage"             g3_tests
  gate "G4 SAST (semgrep)"                    g4_sast
  gate "G5 dependency audit (npm audit)"      g5_deps
  gate "G7 IaC misconfiguration (trivy config)" g7_iac
  gate "G6 build + image scan (trivy image)"  g6_build_and_scan

  printf '\n━━━ SUMMARY ━━━\n'
  printf '%s\n' "${RESULTS[@]}"
} 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | tee "$EVIDENCE/ci-local-run.log"

grep -q '^FAIL' "$EVIDENCE/ci-local-run.log" && exit 1 || exit 0
