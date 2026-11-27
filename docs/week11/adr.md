# Week 11 — Architecture Decision Records

## ADR-W11-01 · Circuit breaker and fallback in the application, transport resilience in the mesh

**Status:** accepted

**Context:**
- The only synchronous dependency on the order path is orders → catalog (price and stock lookup).
- A slow catalog makes every order wait. Before Week 11 orders waited up to 2 s per call and then answered 502.
- Week 10 put an Envoy sidecar next to every service. Envoy has its own "circuit breaking" (connection-pool limits) and outlier detection, so the mesh could own part of the problem.
- The assignment names Resilience4j / Envoy / Istio as possible places for the rules.

**Options considered**
| Option | For | Against |
|---|---|---|
| Everything in Istio (DestinationRule connectionPool + outlierDetection, VirtualService retries/timeouts) | No code change; the same for every service. | Envoy's "circuit breaker" is a concurrency limit, not a closed/open/half-open state machine. Outlier detection ejects *one bad pod*; it cannot say "catalog as a whole is sick". The mesh cannot serve a business fallback (a cached price), it can only fail. |
| Everything in the app | Full control, unit-testable. | Re-implements transport concerns (connect timeout, pod ejection) per language. |
| **Split by responsibility** | The app owns what needs business meaning: the breaker state, the fallback (last-known-good product), which calls are idempotent and may be retried. The mesh owns transport: connect timeout, pool limits (bulkhead), ejecting a broken pod, retrying a request that never reached the app. | Two places to look when tuning. The two retry layers must be budgeted together. |

**Decision**
- **orders 1.2.0** (`services/orders/src/`) wraps the catalog call, outermost first:
  1. fallback: last-known-good product from an in-memory cache (TTL 10 min); the order is accepted with `degraded: true` and an `X-Degraded` header. With no cached product: **503 + `Retry-After`**, never a 502 after a long wait;
  2. retry: up to 3 attempts, exponential backoff 50·2ⁿ ms capped at 500 ms, **full jitter**. Only for connection errors and 502/503/504 — **not for timeouts** (a slow service would get twice the load);
  3. circuit breaker: count-based sliding window of 20 calls; opens at ≥ 50 % failures (min. 10 calls) or 5 consecutive failures; open for 15 s; 3 trial calls in half-open;
  4. timeout 1000 ms per attempt.
- Each retry attempt goes through the breaker, so an open breaker also stops the retries (Resilience4j's Retry(CircuitBreaker(call)) order).
- Thresholds are chart values (`services.orders.env`, CB_* / RETRY_*), not constants.
- The mesh keeps transport: connect timeout 1 s, outlier detection (Week 10), plus Week 11 bulkhead and route timeouts ([ADR-W11-03](#adr-w11-03--mesh-retries-only-where-the-request-never-reached-the-app-bulkhead-per-caller)).
- No library: the breaker is ~100 lines with 100 % line coverage; opossum / cockatiel would add a dependency for the same state machine.

**Consequences**
- E1/E2 ([README §6](README.md#6-chaos-experiments)): the user sees 201 (degraded) instead of 502 while catalog is slow or unreachable; p50 stays at ~10–30 ms while the breaker is open.
- The experiments showed that a breaker on one edge is not enough: orders 1.2.1 and 1.2.2 had to fix the database connect and the keep-alive race with the sidecar before E1 reached 0 % errors (post-mortem PM-W11-02).
- Orders accepted from the cache may carry a stale price. Accepted for the lab; in production the `degraded` flag would feed a re-pricing job.
- The cache is per pod and in memory: a fresh pod has no fallback until it has seen the product once (E2: 503 for the never-seen product).
- Breaker state is per pod. With 2 orders replicas, each trips on its own (observed 1–2 s apart in E1).

## ADR-W11-02 · Chaos Mesh, installed by Argo CD, allowed only in dev and staging

**Status:** accepted

**Context:**
- The lab asks for a chaos experiment (Chaos Mesh or LitmusChaos) with a written hypothesis.
- The faults needed: network latency and partition between two services, and killing a pod.
- prod is behind a manual approval gate (Week 8) and must never be a chaos target.

**Options considered**
| Option | For | Against |
|---|---|---|
| **Chaos Mesh 2.8.8** | Declarative CRDs (`NetworkChaos`, `PodChaos`) that fit git review; tc/netem in the target pod's network namespace — precise source/target selection; namespace allow-list (`enableFilterNamespace`). | A privileged DaemonSet with the containerd socket on every worker. |
| LitmusChaos | ChaosHub catalogue, probes built into the experiment. | Heavier control plane (portal, MongoDB); experiments run as Jobs. |
| Istio fault injection (VirtualService `fault`) | Already installed, no extra privileges. | HTTP-level only: it fakes a delay inside Envoy, it does not slow the network. No pod kill, no partition. |

**Decision**
- Chaos Mesh from the official chart, pinned to **2.8.8**, as Argo CD Application `chaos-mesh` in its own `AppProject chaos` (source: only `charts.chaos-mesh.org`; destination: only `chaos-mesh`).
- Values: containerd runtime (`/run/containerd/containerd.sock`), 1 controller replica, no dashboard, no DNS server.
- Guardrail: `controllerManager.enableFilterNamespace: true`. Only namespaces annotated `chaos-mesh.org/inject: enabled` can be targeted. The annotation is set in [`k8s/platform/environments.yaml`](../../k8s/platform/environments.yaml) on `shop-dev` and `shop-staging` only — owned by the platform project, so an application change cannot add prod.
- Experiments live in [`k8s/chaos/experiments/`](../../k8s/chaos/experiments/) but are **not** synced by Argo CD: an experiment is an action with a start and an end, run by [`scripts/chaos-experiment.py`](../../scripts/chaos-experiment.py), which also deletes it. A sync must never restart a fault.
- CI validates the experiment YAML against the Chaos Mesh CRD schemas (extracted into [`ci/schemas/`](../../ci/schemas/), because the public CRD catalogue has none).

**Consequences**
- The chaos daemon is the most privileged workload in the cluster (privileged, host PID, containerd socket). Its namespace is the only one with PSA `privileged` apart from `istio-system`.
- The chart generates a new webhook certificate on every render: Argo CD needs `ignoreDifferences` on the Secret and the webhooks' `caBundle`, otherwise it would rotate the certificate in a loop.
- A test that aimed a fault at `shop-prod` (to prove the guardrail) was not run: applying it was refused by the operator's safety policy, which is the stronger form of the same guardrail. The evidence for the guardrail is the configuration ([`evidence/05`](evidence/05-chaos-mesh-install.txt)).

## ADR-W11-03 · Mesh retries only where the request never reached the app; bulkhead per caller

**Status:** accepted

**Context:**
- Without a VirtualService, Istio applies a default retry policy (2 retries on `connect-failure, refused-stream, unavailable, cancelled, retriable-status-codes`).
- orders now retries in the app too. Two independent retry layers multiply: 3 app attempts × 3 Envoy attempts = up to **9** requests to catalog for one order — a retry storm exactly when catalog is weakest.
- `POST /api/orders` is not idempotent; retrying it after it reached orders could create two orders.

**Decision**
- Every service gets an explicit east-west VirtualService (the chart renders one per service, the Week 10 canary VS is now one of them) and the edge VS gets the same rule:
  - `timeout: 10s` per route (an upper bound, the apps have tighter ones);
  - `retries.attempts: 1`, `retryOn: connect-failure,refused-stream` — only failures where the request **never reached** the upstream app, so retrying is safe even for POST.
- Worst case per order: 3 app attempts × 2 Envoy attempts = 6, and only for connection failures.
- Bulkhead: `DestinationRule.trafficPolicy.connectionPool.http` — at most 32 pending / 64 active requests from one caller's sidecar to one service; overflow is a fast 503 (`UO`) instead of a queue that ties up every orders worker.

**Consequences**
- Seen in E1: during the injected 3 s latency, *new* TCP connections fail at the 1 s connect timeout (the SYN-ACK is delayed too). Envoy answers 503 `UF`, which the app treats as a retryable error, not as a timeout ([README §7.2](README.md#72-what-the-experiments-revealed)).
- The bulkhead shed load for real in E1 run 2: 6 orders got 503 `UO` at the gateway while orders was CPU-starved, before its breakers opened. A fast 503 instead of a queue is the intended trade-off.
- The schema of the chart validates `retryOn` against a list of safe values, so a later `retryOn: 5xx` on a POST route needs a schema change and a review.

## ADR-W11-04 · Rate limiting at the environment's gateway with Envoy's local rate limit

**Status:** accepted

**Context:**
- A burst (a client retry loop, a scraper, a load test pointed at the wrong environment) should be rejected at the edge, before it fills the queues of orders and catalog.
- Istio has no first-class rate-limit API. The options are an `EnvoyFilter` (local, per pod) or the global rate-limit service (Envoy RLS + Redis).

**Decision**
- Envoy **local rate limit** filter at `shop-gateway`, inserted before the router by an `EnvoyFilter` rendered from the chart ([`templates/resilience.yaml`](../../charts/shoplite/templates/resilience.yaml)) when `mesh.gateway.rateLimit.enabled`.
- Token bucket per gateway pod: **200** tokens, refilled with **100 per second**. Over the limit: `429` with `x-local-rate-limit: true` and `Retry-After: 1`, generated by the gateway.
- Enabled in dev and staging. prod keeps the setting off until its approved sync.
- `EnvoyFilter` was added to the `shoplite` AppProject's namespaced whitelist. It is the most powerful Istio object (it patches raw Envoy config), so it stays limited to the `shop-*` namespaces of that project and to the chart, which CODEOWNERS reviews.

**Consequences**
- The limit is per gateway pod: 2 gateway replicas = 2 buckets = twice the budget. A global limit would need the RLS service.
- Measured ([`evidence/04`](evidence/04-ratelimit-probe.txt)): 1000 requests in 1.3 s → 325 passed, 675 × 429; a steady 50 req/s → 0 × 429.
- Monitoring gap: the local reply never passes Istio's stats filter, so `istio_requests_total` shows no 429s, and Istio's default stats matcher drops Envoy's `http_local_rate_limiter.*` counters. Follow-up A6.

## ADR-W11-05 · Workload certificate lifetime 7 days + an alert on its expiry (post-mortem PM-W11-01)

**Status:** accepted

**Context:**
- On 2026-11-26 dev and staging were found down after ~10 days: every workload certificate had expired on 2026-11-25 ([README §2](README.md#2-incident-pm-w11-01--expired-workload-certificates)).
- istio-agent schedules the renewal of its 24 h certificate on a monotonic-clock timer; while the laptop sleeps, the Docker VM is suspended and the timer stops, but the expiry is wall-clock time.
- Nothing alerted, although `istio_agent_cert_expiry_seconds` was already in Prometheus.

**Options considered**
| Option | For | Against |
|---|---|---|
| Keep 24 h, restart pods by hand after a long sleep | Shortest exposure of a stolen certificate. | It happened twice in 10 days. Manual. |
| **`SECRET_TTL=168h`** (istiod allows up to 90 d) | Survives several nights of laptop sleep; one line of config. | A leaked key stays valid up to 7 days (AuthorizationPolicy and STRICT mTLS still apply). |
| cert-manager istio-csr / external CA | Production-grade, central rotation. | Same agent timer on the workload side; far more moving parts for a lab. |

**Decision**
- `meshConfig.defaultConfig.proxyMetadata.SECRET_TTL: "168h"` in [`k8s/mesh/istiod-values.yaml`](../../k8s/mesh/istiod-values.yaml).
- Alerts in [`shoplite-red.rules.yml`](../../k8s/observability/config/shoplite-red.rules.yml), with a promtool test that replays the incident:
  - `IstioWorkloadCertExpiring` (ticket): less than 25 % of the lifetime left for 5 min, i.e. rotation is overdue;
  - `IstioWorkloadCertExpired` (page): ≤ 0 s left — restart the pod.

**Consequences**
- After the sync and a rollout restart, every sidecar in dev/staging holds a certificate valid until 2026-12-03 ([`evidence/02`](evidence/02-recovery-after-ttl-fix.txt)).
- On a host that never sleeps the default 24 h would be fine; the alert is what makes either value safe.
