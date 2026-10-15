#!/usr/bin/env bash
# Renders every diagram-as-code source in docs/ to SVG + PNG (Mermaid) and PNG (Python Diagrams).
# Only Docker is required; images come from mirror.gcr.io to avoid Docker Hub pull limits.
set -euo pipefail
cd "$(dirname "$0")/.."
MERMAID_IMAGE=mirror.gcr.io/minlag/mermaid-cli:latest
PYTHON_IMAGE=mirror.gcr.io/library/python:3.12-slim

for src in docs/week6/diagrams/*.mmd docs/week7/diagrams/*.mmd; do
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
ls -1 docs/week6/diagrams docs/week7/diagrams
