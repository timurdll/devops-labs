#!/usr/bin/env bash
# Renders every diagram-as-code source in docs/ to SVG + PNG (Mermaid) and PNG (Python Diagrams).
# Only Docker is required; images come from mirror.gcr.io to avoid Docker Hub pull limits.
set -euo pipefail
cd "$(dirname "$0")/.."
MERMAID_IMAGE=mirror.gcr.io/minlag/mermaid-cli:latest
PYTHON_IMAGE=mirror.gcr.io/library/python:3.12-slim

for src in docs/week6/diagrams/*.mmd docs/week7/diagrams/*.mmd docs/week8/diagrams/*.mmd docs/week9/diagrams/*.mmd; do
  base="${src%.mmd}"
  echo "mermaid  $src"
  docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/data" "$MERMAID_IMAGE" \
    -q -c /data/docs/mermaid.config.json -b white -i "/data/$src" -o "/data/$base.svg"
  docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/data" "$MERMAID_IMAGE" \
    -q -c /data/docs/mermaid.config.json -b white -s 2 -i "/data/$src" -o "/data/$base.png"
done

echo "diagrams docs/week7/diagrams/k8s_topology.py"
docker run --rm -v "$PWD:/w" -w /w "$PYTHON_IMAGE" sh -c '
  apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends graphviz fonts-dejavu-core >/dev/null &&
  pip install -q --root-user-action=ignore --disable-pip-version-check diagrams==0.25.1 &&
  python docs/week7/diagrams/k8s_topology.py'
echo "pillow   docs/week9/diagrams (wireframe + trace waterfalls from docs/week9/exports/traces)"
docker run --rm -v "$PWD:/w" -w /w "$PYTHON_IMAGE" sh -c '
  apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends fonts-dejavu-core >/dev/null &&
  pip install -q --root-user-action=ignore --disable-pip-version-check pillow==12.0.0 &&
  python docs/week9/diagrams/grafana_wireframe.py &&
  python docs/week9/diagrams/trace_waterfall.py docs/week9/exports/traces/order-ok.json docs/week9/diagrams/trace-waterfall-ok.png "POST /api/orders · prod · 201 Created" &&
  python docs/week9/diagrams/trace_waterfall.py docs/week9/exports/traces/order-catalog-down.json docs/week9/diagrams/trace-waterfall-error.png "POST /api/orders · prod · catalog scaled to 0 → 502"'
ls -1 docs/week6/diagrams docs/week7/diagrams docs/week8/diagrams docs/week9/diagrams
