#!/usr/bin/env bash
# Proves that the security gates actually block: plants a fake token and injectable code
# in a throw-away repo and runs G1 (gitleaks) and G4 (semgrep) against it.
# Expected: every gate below exits 1. Evidence → docs/week6/evidence/negative-tests.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ci_env() { grep -E "^  $1:" "$ROOT/.github/workflows/ci.yml" | awk '{print $2}'; }
GITLEAKS_IMAGE=$(ci_env GITLEAKS_IMAGE)
SEMGREP_IMAGE=$(ci_env SEMGREP_IMAGE)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" && cd "$WORK" && git init -q -b main
FAKE_TOKEN="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"   # random, not a real token
printf "'use strict';\nmodule.exports = { githubToken: '%s' };\n" "$FAKE_TOKEN" > src/config.js
cat > src/handler.js <<'JS'
'use strict';
const { exec } = require('node:child_process');
module.exports = function handler(req, res) {
  const expr = new URL(req.url, 'http://x').searchParams.get('q');
  res.end(String(eval(expr)));            // code injection
  exec('ls ' + req.headers['x-dir']);     // command injection
};
JS
cat > src/repo.js <<'JS'
'use strict';
module.exports = (pool, req) => pool.query(`SELECT * FROM products WHERE sku = '${req.headers['x-sku']}'`);
JS
cp -r "$ROOT/.semgrep" .semgrep-rules
git add -A

{
  echo "Negative tests — $(date -u '+%Y-%m-%d %H:%M UTC'). Every gate below is expected to FAIL (exit 1)."
  echo; echo "━━━ T1 · G1 gitleaks: commit contains a (fake) GitHub token ━━━"
  docker run --rm -v "$WORK:/repo" -w /repo "$GITLEAKS_IMAGE" git /repo --staged --redact --verbose --exit-code 1 --no-banner
  echo ">>> gitleaks exit code: $?"

  echo; echo "━━━ T2 · G4 semgrep, public packs only (p/javascript, p/nodejs) ━━━"
  docker run --rm -v "$WORK:/src" -w /src "$SEMGREP_IMAGE" semgrep scan \
    --config p/javascript --config p/nodejs --metrics off --error --text
  echo ">>> semgrep exit code: $?   (0 = FALSE NEGATIVE: public rules miss these sinks in plain node:http code)"

  echo; echo "━━━ T3 · G4 semgrep, public packs + project rules (.semgrep/) — the configuration used in ci.yml ━━━"
  docker run --rm -v "$WORK:/src" -w /src "$SEMGREP_IMAGE" semgrep scan \
    --config p/javascript --config p/nodejs --config .semgrep-rules/ --metrics off --error --text
  echo ">>> semgrep exit code: $?"
} 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | tee "$ROOT/docs/week6/evidence/negative-tests.log"
