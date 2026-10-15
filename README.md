# DevOps Labs: ShopLite

A small microservice shop used as the system under test for the Software Architecture & DevOps labs.

| Lab | Topic | Report |
|---|---|---|
| **Week 6 · Lab 2** | CI/CD architecture & DevSecOps threat modeling (quality gates, STRIDE, Trivy) | [docs/week6/README.md](docs/week6/README.md) |
| **Week 7 · Lab 3** | Kubernetes cluster topology & microservices architecture (kind, Ingress, ConfigMaps/Secrets) | [docs/week7/README.md](docs/week7/README.md) |

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
k8s/                         Kustomize manifests: platform (Traefik) + shop
scripts/
  ci-local.sh                run every CI gate locally with the same pinned tool images
  negative-tests.sh          prove the secret and SAST gates block bad changes
  k8s-up.sh                  create cluster, generate secrets, build/load images, deploy
  k8s-verify.sh              capture kubectl evidence, compare design vs runtime
  k8s-rollout-test.sh        zero-downtime rolling restart under load
  render-diagrams.sh         render all diagrams-as-code (Mermaid + Python Diagrams)
docs/week6, docs/week7       reports, diagram sources (.mmd / .py) + renders, evidence
```

## Quick start

Requirements: Docker, Node.js 24, kubectl, kind.

```bash
./scripts/ci-local.sh          # Week 6: all gates; evidence → docs/week6/evidence
./scripts/k8s-up.sh            # Week 7: cluster + deploy
./scripts/k8s-verify.sh        # Week 7: evidence → docs/week7/evidence
curl -H 'Host: shop.local' http://127.0.0.1:8080/api/catalog/products
kind delete cluster --name shoplite   # clean up
```

To open the UI in a browser, add `127.0.0.1 shop.local` to `/etc/hosts` and go to <http://shop.local:8080>.
