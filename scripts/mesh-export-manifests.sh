#!/usr/bin/env bash
# Week 10 — exports the Istio custom resources that git produces, per environment, into
# docs/week10/manifests/ (deliverable "Istio CRD manifest files"). The source of truth stays
# charts/shoplite/templates/mesh.yaml + environments/<env>/values.yaml and k8s/mesh/; these files are
# the rendered result, i.e. exactly what Argo CD applies. Regenerate after changing either.
# Usage: scripts/mesh-export-manifests.sh        (Docker + kubectl)
set -euo pipefail
cd "$(dirname "$0")/.."
HELM_IMAGE=$(grep -E '^  HELM_IMAGE:' .github/workflows/ci.yml | awk '{print $2}')
out=docs/week10/manifests; mkdir -p "$out"

{ echo "# Rendered from k8s/mesh (Argo CD Application mesh-config, namespace istio-system). Do not edit."
  kubectl kustomize k8s/mesh; } > "$out/00-mesh-wide.yaml"

for env in dev staging prod; do
  docker run --rm -v "$PWD:/repo" -w /repo "$HELM_IMAGE" template shoplite charts/shoplite -n "shop-$env" \
    -f "environments/$env/values.yaml" --set "global.environment=$env" | python3 -c '
import sys, re
env = sys.argv[1]
docs = [d for d in sys.stdin.read().split("\n---\n") if re.search(r"(?m)^apiVersion: (networking|security|telemetry)\.istio\.io/", d)]
order = ["Gateway", "VirtualService", "DestinationRule", "PeerAuthentication", "AuthorizationPolicy", "Telemetry"]
kind = lambda d: re.search(r"(?m)^kind: (\S+)", d)[1]
docs.sort(key=lambda d: order.index(kind(d)))
print("# Istio custom resources rendered by charts/shoplite for shop-%s (helm template, values from" % env)
print("# environments/%s/values.yaml). Do not edit — change the chart or the values and re-run" % env)
print("# scripts/mesh-export-manifests.sh. %d resources: %s" % (len(docs), ", ".join(sorted({kind(d) for d in docs}, key=order.index))))
print("---\n" + "\n---\n".join(d.strip("-\n") for d in docs))' "$env" > "$out/shop-$env.yaml"
  echo "$out/shop-$env.yaml: $(grep -c '^kind:' "$out/shop-$env.yaml") Istio resources"
done
