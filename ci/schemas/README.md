JSON schemas for CRDs that are not in the datree CRDs-catalog, extracted from the installed CRDs
(`openAPIV3Schema`, unknown fields rejected) for `kubeconform -strict`.

- `chaos-mesh.org/` — Chaos Mesh 2.8.8 NetworkChaos and PodChaos (Week 11). Regenerate after a
  chart upgrade: `kubectl get crd networkchaos.chaos-mesh.org -o json` → `.spec.versions[v1alpha1].schema.openAPIV3Schema`.
