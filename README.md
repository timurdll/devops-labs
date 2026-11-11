# DevOps Labs: ShopLite

A small microservice shop used as the system under test for the Software Architecture & DevOps labs.

| Lab | Topic | Report |
|---|---|---|
| **Week 6 · Lab 2** | CI/CD architecture & DevSecOps threat modeling (quality gates, STRIDE, Trivy) | [docs/week6/README.md](docs/week6/README.md) · [.docx](docs/week6/Week6-Lab2-Report.docx) |
| **Week 7 · Lab 3** | Kubernetes cluster topology & microservices architecture (kind, Ingress, ConfigMaps/Secrets) | [docs/week7/README.md](docs/week7/README.md) · [.docx](docs/week7/Week7-Lab3-Report.docx) |
| **Week 8 · Lab 4** | GitOps delivery architecture & Helm package design (Helm chart, dev/staging/prod, Argo CD) | [docs/week8/README.md](docs/week8/README.md) · [.docx](docs/week8/Week8-Lab4-Report.docx) |
| **Week 9 · Lab 5** | Distributed observability & telemetry data flow (Prometheus SDK, OpenTelemetry, Collector, Jaeger, Grafana RED) | [docs/week9/README.md](docs/week9/README.md) · [.docx](docs/week9/Week9-Lab5-Report.docx) |
| **Week 10 · Lab 6** | Service mesh architecture & inter-service communication (Istio/Envoy sidecars, STRICT mTLS, identity-based authorization, 90/10 canary) | [docs/week10/README.md](docs/week10/README.md) · [.docx](docs/week10/Week10-Lab6-Report.docx) |

## Repository layout

```
.github/workflows/ci.yml     CI pipeline with gates G1–G8 (Week 6)
.github/dependabot.yml       pinned-dependency updates with a 7-day cooldown
.github/CODEOWNERS           review ownership for pipeline / policy / cluster config
.semgrep/                    project-specific SAST rules
.trivyignore.yaml            scoped, justified, expiring risk acceptances
services/catalog             Node.js 24 · product API      · distroless image · /metrics + OTel traces (Week 9) · ?q= search (1.2.0, Week 10 canary)
services/orders              Node.js 24 · order API        · distroless image (calls catalog) · /metrics + OTel traces
services/web                 nginx-unprivileged · static UI
kind/cluster.yaml            3-node local cluster (Week 7)
k8s/                         Kustomize manifests: platform (Traefik, env namespaces) + shop
charts/shoplite/             Helm chart of ShopLite + values.schema.json (Week 8)
environments/<env>/          per-environment values: dev, staging, prod (Week 8)
gitops/                      Argo CD install, root app-of-apps, AppProjects, ApplicationSet (Week 8)
k8s/observability/           OTel Collector, Prometheus (+ RED rules), Jaeger, Grafana (+ RED dashboard) (Week 9)
k8s/mesh/                    Istio values (istiod, istio-cni) + mesh-wide STRICT PeerAuthentication, tracing Telemetry (Week 10)
charts/shoplite/templates/mesh.yaml   per-env gateway, VirtualService, DestinationRule, PeerAuthentication, AuthorizationPolicy (Week 10)
scripts/
  ci-local.sh                run every CI gate locally with the same pinned tool images
  negative-tests.sh          prove the secret and SAST gates block bad changes
  k8s-up.sh                  create cluster, generate secrets, build/load images, deploy
  k8s-verify.sh              capture kubectl evidence, compare design vs runtime
  k8s-rollout-test.sh        zero-downtime rolling restart under load
  gitops-up.sh               install Argo CD, environment secrets, bootstrap the root app (Week 8)
  gitops-sync-prod.sh        prod approval gate: diff, then sync
  gitops-verify.sh           design (helm template of git) vs runtime, traffic + isolation tests
  gitops-demo.sh             commit → dev sync, drift → self-heal, commit → prod waits for approval
  gitops-watch.sh            print every state transition of an Argo CD Application
  observability-up.sh        Grafana secret, observability stack via Argo CD (Week 9)
  telemetry-load.sh          synthetic users against one environment
  telemetry-experiment.sh    load on all envs + catalog outage in prod
  telemetry-verify.py        design vs runtime along the telemetry data flow, JSON exports
  mesh-mtls-probe.sh         tcpdump in a pod's netns: mTLS vs plaintext under PERMISSIVE / STRICT (Week 10)
  mesh-authz-probe.sh        label-forging pod (wrong identity) → 403, real caller → 200
  mesh-canary-check.sh       90/10 split counted by client, gateway access log and Envoy metrics
  mesh-diagnose.sh           istioctl proxy-status, analyze, describe, proxy-config, authz check
  mesh-export-manifests.sh   rendered Istio CRs per environment → docs/week10/manifests
  render-diagrams.sh         render all diagrams-as-code (Mermaid + Python Diagrams)
docs/week6 … docs/week10    reports, diagram sources (.mmd / .py) + renders, evidence
```

## Quick start

Requirements: Docker, Node.js 24, kubectl, kind; Week 8 also Helm 4 and the argocd CLI; Week 9 also Python 3; Week 10 also istioctl 1.31.4.

```bash
./scripts/ci-local.sh          # Week 6: all gates; evidence → docs/week6/evidence
./scripts/k8s-up.sh            # Week 7: cluster + deploy
./scripts/k8s-verify.sh        # Week 7: evidence → docs/week7/evidence
curl -H 'Host: shop.local' http://127.0.0.1:8080/api/catalog/products
./scripts/gitops-up.sh         # Week 8: Argo CD + dev/staging/prod from git
./scripts/gitops-sync-prod.sh  # Week 8: approve the prod release
./scripts/gitops-verify.sh     # Week 8: evidence → docs/week8/evidence
./scripts/observability-up.sh  # Week 9: Collector, Prometheus, Jaeger, Grafana
./scripts/telemetry-experiment.sh   # Week 9: load + fault (port-forwards: see docs/week9 §8)
./scripts/telemetry-verify.py --export docs/week9/exports   # Week 9: 49 checks + JSON exports
./scripts/mesh-canary-check.sh staging 1000 400   # Week 10: canary split (more: docs/week10 §10)
./scripts/mesh-diagnose.sh staging  # Week 10: istioctl diagnostics
kind delete cluster --name shoplite   # clean up
```

To open the UI in a browser, add `127.0.0.1 shop.local` to `/etc/hosts` and go to <http://shop.local:8080>.
