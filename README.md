# DevOps Labs: ShopLite

A small microservice shop used as the system under test for the Software Architecture & DevOps labs.

| Lab | Topic | Report |
|---|---|---|
| **Week 6 · Lab 2** | CI/CD architecture & DevSecOps threat modeling (quality gates, STRIDE, Trivy) | [docs/week6/README.md](docs/week6/README.md) · [.docx](docs/week6/Week6-Lab2-Report.docx) |
| **Week 7 · Lab 3** | Kubernetes cluster topology & microservices architecture (kind, Ingress, ConfigMaps/Secrets) | [docs/week7/README.md](docs/week7/README.md) · [.docx](docs/week7/Week7-Lab3-Report.docx) |
| **Week 8 · Lab 4** | GitOps delivery architecture & Helm package design (Helm chart, dev/staging/prod, Argo CD) | [docs/week8/README.md](docs/week8/README.md) · [.docx](docs/week8/Week8-Lab4-Report.docx) |

## Repository layout

```
.github/workflows/ci.yml     CI pipeline with gates G1–G8 (Week 6)
.github/dependabot.yml       pinned-dependency updates with a 7-day cooldown
.github/CODEOWNERS           review ownership for pipeline / policy / cluster config
.semgrep/                    project-specific SAST rules
.trivyignore.yaml            scoped, justified, expiring risk acceptances
services/catalog             Node.js 24 · product API      · distroless image
services/orders              Node.js 24 · order API        · distroless image (calls catalog)
services/web                 nginx-unprivileged · static UI
kind/cluster.yaml            3-node local cluster (Week 7)
k8s/                         Kustomize manifests: platform (Traefik, env namespaces) + shop
charts/shoplite/             Helm chart of ShopLite + values.schema.json (Week 8)
environments/<env>/          per-environment values: dev, staging, prod (Week 8)
gitops/                      Argo CD install, root app-of-apps, AppProjects, ApplicationSet (Week 8)
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
  render-diagrams.sh         render all diagrams-as-code (Mermaid + Python Diagrams)
docs/week6 … docs/week8     reports, diagram sources (.mmd / .py) + renders, evidence
```

## Quick start

Requirements: Docker, Node.js 24, kubectl, kind; Week 8 also Helm 4 and the argocd CLI.

```bash
./scripts/ci-local.sh          # Week 6: all gates; evidence → docs/week6/evidence
./scripts/k8s-up.sh            # Week 7: cluster + deploy
./scripts/k8s-verify.sh        # Week 7: evidence → docs/week7/evidence
curl -H 'Host: shop.local' http://127.0.0.1:8080/api/catalog/products
./scripts/gitops-up.sh         # Week 8: Argo CD + dev/staging/prod from git
./scripts/gitops-sync-prod.sh  # Week 8: approve the prod release
./scripts/gitops-verify.sh     # Week 8: evidence → docs/week8/evidence
kind delete cluster --name shoplite   # clean up
```

To open the UI in a browser, add `127.0.0.1 shop.local` to `/etc/hosts` and go to <http://shop.local:8080>.
