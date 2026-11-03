# Week 8 — Architecture Decision Records

## ADR-W8-01 · Argo CD as the GitOps controller

**Status:** accepted · **Context:** the lab requires a pull-based controller that reconciles the cluster with git. Candidates: Argo CD and Flux.

**Decision:** Argo CD v3.5.6 (non-HA install, pinned in [`gitops/argocd/kustomization.yaml`](../../gitops/argocd/kustomization.yaml)).

**Reasons**
- **ApplicationSet** generates the three environment Applications from a single template, so the environments cannot drift structurally.
- **AppProject** gives Argo CD its own RBAC boundary. The `shoplite` project cannot create cluster-scoped objects and cannot deploy outside `shop-dev|staging|prod`.
- Sync status and health are first-class API fields, so the state machine (§2 of the README) can be observed with `kubectl` and recorded as evidence.
- The UI shows the diff for a manual prod approval.

**Consequences:** about 7 extra pods and roughly 600 MiB of RAM on the kind cluster. Flux would be lighter (no UI, no Redis). Flux's `HelmRelease` would also have been a good fit, so that is the alternative to keep in mind for constrained clusters.

## ADR-W8-02 · Environments = directory per environment on one branch, namespace per environment

**Status:** accepted

**Options considered**

| Option | Verdict |
|---|---|
| Branch per environment (`dev`, `staging`, `prod` branches) | ✗ Promotion is a merge between long-lived branches, so the branches diverge and unrelated changes get promoted along with the intended one. |
| Repository per environment | ✗ Too heavy for one team. Would make sense if prod access had to be split by repository permissions. |
| Kustomize overlays on the Week 7 YAML | ✗ Works, but the assignment asks for a reusable Helm package, and overlays patch YAML instead of exposing a typed parameter contract. |
| **One chart + `environments/<env>/values.yaml` on one branch** | ✓ A change to one environment is one file in one commit. Promotion = a PR that copies a value from `dev` to `staging` to `prod`. The full history of every environment is `git log environments/<env>`. |

Each environment gets its own namespace (`shop-<env>`) with PSA *restricted*, its own Secret and its own database. The namespaces belong to the **platform** Application, not to the chart.

## ADR-W8-03 · Database credentials stay out of git (for now)

**Status:** accepted for the lab, to be replaced before production.

GitOps says *everything* is in git, but a Secret in git is only base64-encoded. The chart therefore references `database.existingSecret` and never renders a Secret. `scripts/gitops-up.sh` creates `db-credentials` in each namespace from a git-ignored, randomly generated `environments/<env>/db.env`. Argo CD does not track that object, so it never shows up as drift or gets pruned.

**Production path:** Sealed Secrets (encrypted SealedSecret objects in git, decrypted in-cluster) or External Secrets Operator (git holds only a reference to Vault or a cloud secret manager). Either one restores *git = full desired state* without plaintext in git.

## ADR-W8-04 · Sync policy per environment

| Env | Automated | Prune | Self-heal | Why |
|---|---|---|---|---|
| dev | ✓ | ✓ | ✓ | Every commit is deployed. Fastest feedback. |
| staging | ✓ | ✓ | ✓ | Same as dev, but production-shaped (2 replicas, PDBs). |
| prod | ✗ | (on manual sync) | ✗ | **Human approval gate**: Argo CD reports `OutOfSync` and shows the diff, and an operator runs [`scripts/gitops-sync-prod.sh`](../../scripts/gitops-sync-prod.sh). |
| platform | ✓ | ✗ | ✓ | Auto-pruning a Namespace would delete a whole environment. |

All Applications retry failed syncs 5 times with exponential backoff (10 s × 2ⁿ, capped at 3 min).

## ADR-W8-05 · Change detection by 30 s polling

The kind cluster is not reachable from GitHub, so a push webhook cannot reach Argo CD. `timeout.reconciliation` is lowered from 120 s to 30 s with no jitter, which bounds commit-to-detection time at about 30 s plus render time. **Production:** a GitHub webhook to `argocd-server /api/webhook` for immediate refresh, keeping the poll (default 120 s plus jitter) as a fallback.
