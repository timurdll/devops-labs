# Week 11 (Lab 7): System Resilience Patterns & Fault Tree Analysis

Word version of this report: [`Week11-Lab7-Report.docx`](Week11-Lab7-Report.docx). Architecture decisions: [`adr.md`](adr.md).

**System:** ShopLite from Weeks 7–10 (Traefik → per-environment Envoy gateway → `web`, `catalog`, `orders` → PostgreSQL, all in an Istio mesh with STRICT mTLS) in three GitOps environments on the kind cluster.

This week asks how ShopLite fails and makes it fail well:
- a **failure-mode analysis** (FMEA) and a **fault tree** for the most important user action, placing an order;
- **resilience patterns** where the analysis says they pay off: circuit breaker, retry with exponential backoff and jitter, fallback, timeouts, bulkhead, rate limiter;
- **chaos experiments** with Chaos Mesh that state a hypothesis, inject the fault under load and check the hypothesis automatically;
- **post-mortems**. One is for a chaos experiment. The other is for a *real* outage of dev and staging, found on the first day of this lab before any change was made.

| Deliverable (from the assignment) | Where it is |
|---|---|
| Circuit Breaker State Machine diagram (Closed / Open / Half-Open, trip thresholds, reset timeouts) | [§4.1](#41-circuit-breaker) · [`diagrams/circuit-breaker.mmd`](diagrams/circuit-breaker.mmd) |
| Fault Tree Analysis chart | [§3.2](#32-fault-tree) · [`diagrams/fault-tree.mmd`](diagrams/fault-tree.mmd) |
| Failure-mode analysis; resilience patterns: Circuit Breaker, Rate Limiter, Retry with Exponential Backoff | [§3.1](#31-fmea) · [§4](#4-resilience-patterns) |
| Chaos hypothesis ("3000 ms latency in Service B triggers the breaker and returns a cached fallback") | [§6.1](#61-e1--3000-ms-latency-in-catalog-the-assignments-hypothesis) |
| Resilience proxy rule (Envoy / Istio) | [§4.4](#44-mesh-rules-timeouts-safe-retries-bulkhead) · [§4.5](#45-rate-limiter-at-the-gateway) · [`charts/shoplite/templates/resilience.yaml`](../../charts/shoplite/templates/resilience.yaml) |
| Chaos experiment spec (YAML) | [`k8s/chaos/experiments/`](../../k8s/chaos/experiments/) (Chaos Mesh `NetworkChaos`, `PodChaos`) |
| Post-Mortem Report | [§7](#7-post-mortem-pm-w11-02--chaos-experiment-e1) (experiment) · [§2](#2-incident-pm-w11-01--expired-workload-certificates) (real incident) |

---

## 1. Requirements → design

| Requirement | Design decision |
|---|---|
| Know how the system fails before adding patterns | FMEA of the order path, ranked by RPN, and a fault tree with AND/OR gates for "order cannot be placed" (§3). Patterns go only where a failure mode is likely *and* harmful. |
| Circuit breaker | In **orders**, around the catalog call: closed / open / half-open, count-based window, per-pod state. Business fallback = last-known-good product from a cache ([ADR-W11-01](adr.md#adr-w11-01--circuit-breaker-and-fallback-in-the-application-transport-resilience-in-the-mesh)). |
| Retry with exponential backoff | In orders, for the idempotent GET to catalog only. Full jitter, 3 attempts, no retry on timeout. In the mesh, only for failures where the request never reached the app (ADR-W11-03). |
| Rate limiter | Envoy local rate limit at each environment's gateway, 429 above the token bucket ([ADR-W11-04](adr.md#adr-w11-04--rate-limiting-at-the-environments-gateway-with-envoys-local-rate-limit)). |
| Chaos experiment with Chaos Mesh / LitmusChaos | Chaos Mesh 2.8.8 via Argo CD, allowed only in namespaces annotated for it, so never in prod ([ADR-W11-02](adr.md#adr-w11-02--chaos-mesh-installed-by-argo-cd-allowed-only-in-dev-and-staging)). A runner applies the fault under load, records every second, and checks the hypothesis. |
| Observability of the patterns | Breaker state, transitions, rejected calls, fallbacks and retries as Prometheus metrics. Alert `CircuitBreakerOpen` with a promtool test. |
| GitOps as before | Every change is a commit on `week11-resilience` that Argo CD syncs to dev and staging. prod is untouched and still waits for its approval. |

## 2. Incident PM-W11-01 — expired workload certificates

The first look at the cluster for this lab (2026-11-26, after ~10 days away) showed **dev and staging down**: every request through the edge returned 503. prod, which is not yet in the mesh (Week 10, ADR-W10-04), answered 200. All of this was captured read-only before any change ([`evidence/00`](evidence/00-incident-expired-workload-certs.txt)).

**Summary.** Every Envoy sidecar in `shop-dev` and `shop-staging` held an expired workload certificate (24 h lifetime, expired 2026-11-25 between 01:44 and 11:39 UTC). STRICT mTLS refuses an expired certificate, so every *new* connection between sidecars was reset. Readiness probes open a new database connection, so catalog and orders pods went unready, and the gateway had no healthy endpoints: **503 for every request, for about 36 hours**. Nobody was paged, because no alert existed.

**Impact.** dev and staging unavailable from about 2026-11-25 01:44 UTC until the fix at 2026-11-26 13:23 UTC. No data loss. prod not affected.

**Timeline (UTC)**
| Time | Event |
|---|---|
| 11-16 12:14 | catalog pod renews its certificate (normal; expected every ~12 h, at 50 % of 24 h) |
| 11-18 → 11-24 | renewals arrive after +36 h, +45 h, +71 h and +39 h, all beyond the 24 h lifetime. Twice the certificate expired and healed itself hours later when the timer fired ([`evidence/01`](evidence/01-cert-expiry-in-prometheus.txt)) |
| 11-25 01:44 | postgres' certificate in staging expires; by 11:39 every other sidecar's has too. Not renewed this time |
| 11-26 13:14 | found: catalog `/readyz` 503, a new pg connection from inside the pod fails with `ECONNRESET` after 19 ms |
| 11-26 13:16 | evidence captured: certificate validity of every sidecar, edge status codes, istiod's timer gaps |
| 11-26 13:20 | fix committed (cb89d1b): `SECRET_TTL` 168 h + two alerts. Argo CD synced, dev/staging workloads restarted |
| 11-26 13:23 | every sidecar holds a certificate valid until 12-03; all edge checks return 200 ([`evidence/02`](evidence/02-recovery-after-ttl-fix.txt)) |

**Root cause — 5 whys**
1. *Why 503?* The gateway had no ready endpoints: catalog/orders failed their readiness probe.
2. *Why unready?* `/readyz` opens a new PostgreSQL connection, and the sidecar's mTLS handshake to postgres was refused.
3. *Why refused?* Both sidecars' certificates had expired and STRICT mTLS validates the validity period.
4. *Why expired?* istio-agent schedules the renewal on a timer, and that timer runs on the monotonic clock. The kind nodes live in Docker Desktop's VM, which is suspended while the laptop sleeps. The timer stops, but wall-clock time — and the certificate's `notAfter` — does not. istiod's own hourly check shows the same pattern: 19 gaps of 2–28 h in 10 days.
5. *Why did nobody notice?* `istio_agent_cert_expiry_seconds` was in Prometheus since Week 10 (−35 h at discovery), but no alert rule used it. The Week 9 alerts look at RED metrics, and an environment with no traffic produces no errors.

**What went well**
- prod was unaffected: the phased mesh rollout kept it out of the blast radius.
- The evidence was enough to find the cause in minutes: Envoy's `/certs` admin endpoint, istio-agent logs, Prometheus.

**What went wrong**
- The mesh was operated on defaults that assume a host that never sleeps.
- Monitoring had the signal but no alert.

**Action items**
| # | Action | Status |
|---|---|---|
| A1 | Workload certificate lifetime 24 h → **168 h** (`meshConfig.defaultConfig.proxyMetadata.SECRET_TTL`) | done (cb89d1b) |
| A2 | Alerts `IstioWorkloadCertExpiring` (< 25 % of lifetime left, ticket) and `IstioWorkloadCertExpired` (≤ 0, page), with a promtool test replaying the incident | done ([`tests/mesh-certificates.rules.test.yml`](../../k8s/observability/config/tests/mesh-certificates.rules.test.yml)) |
| A3 | Restart dev/staging workloads to get new certificates | done |
| A4 | Before approving the mesh for prod (Week 10, phase 2): run the cluster on a host that does not sleep, or keep the alert routed to a human | open |

## 3. Failure-mode analysis

### 3.1 FMEA

The order path: client → Traefik → `shop-gateway` → `orders` → (`catalog` → its DB) → orders DB. Scores are 1–10:
- **S** — severity for the customer;
- **O** — occurrence, how likely on this platform;
- **D** — detection, how *hard* it is to detect (10 = invisible).

RPN = S × O × D. The "after" column is the RPN with this week's mitigation and the measured result.

| # | Failure mode | Effect on the order | S | O | D | RPN | Mitigation (Week 11) | RPN after |
|---|---|---|---|---|---|---|---|---|
| F1 | catalog slow (GC pause, DB lock, CPU throttling) | every order waits; orders' workers pile up; 502 after 2 s | 7 | 6 | 5 | **210** | timeout 1 s, circuit breaker, cache fallback, bulkhead (E1) | 7·6·2 = 84; S→3 (degraded 201): **36** |
| F2 | workload certificate expired (PM-W11-01) | whole environment 503 | 9 | 5 | 9 | **405** | TTL 168 h, expiry alerts | 9·2·2 = **36** |
| F3 | catalog unreachable (partition, all pods down) | 502 for every order | 8 | 3 | 4 | 96 | breaker + cache fallback; 503 + Retry-After on cache miss (E2) | 4·3·2 = **24** |
| F4 | one catalog pod dies | a few failed requests during endpoint update | 5 | 6 | 3 | 90 | 2 replicas, transport retry on connect-failure, outlier detection (E3) | 2·6·2 = **24** |
| F5 | traffic burst / retry storm | all services saturated, everyone slow | 7 | 3 | 5 | 105 | gateway rate limit (429), no stacked retries (≤ 6 attempts, not 9) | 3·3·3 = **27** |
| F6 | orders → catalog retry amplification (app × mesh) | catalog overloaded exactly when weakest | 6 | 4 | 7 | 168 | explicit mesh retry policy (only connect-failure, 1 retry), app retry without timeouts, jitter | 6·2·4 = **48** |
| F7 | postgres (single replica) down | orders cannot be stored | 9 | 2 | 3 | 54 | not mitigated this week (StatefulSet with 1 replica; Week 13 looks at the DB) | 54 |
| F8 | orders accepts an order with a stale cached price | wrong price on a degraded order | 4 | 3 | 6 | 72 | order flagged `degraded`, cache TTL 10 min, metric `dependency_fallback_total` | 4·3·2 = **24** |

The two highest RPNs were the slow dependency (F1), which is what the assignment's chaos hypothesis is about, and the certificate expiry (F2). F2 was the one that actually happened.

### 3.2 Fault tree

TOP event: *a customer cannot place an order* (POST `/api/orders` is not 201 within 2 s). An OR gate fails if any input fails, an AND gate only if all inputs fail. The design idea of this week is the **AND gate under E3**. A catalog failure only reaches the customer if there is *also* no fallback. Before Week 11 that branch was a plain OR.

![Fault tree: order cannot be placed (green = mitigated this week, red = the real incident, grey = accepted)](diagrams/fault-tree.png)

Minimal cut sets, i.e. the smallest sets of basic events that cause the TOP event:
- single points of failure, order-1 cut sets: postgres down (B10), certificate expired (B4/B11), all orders pods down (B3), gateway down (B2), rate limit exhausted by legitimate traffic (B1);
- order-2 cut sets created this week: {catalog slow/unreachable/killed} × {product not cached / cache older than 10 min}. Each needs two independent events, so each is much less likely than the order-1 set it replaced.

## 4. Resilience patterns

![Where each pattern lives on the order path](diagrams/resilience-layers.png)

### 4.1 Circuit breaker

![Circuit breaker state machine of orders → catalog](diagrams/circuit-breaker.png)

- Implementation: [`services/orders/src/circuit-breaker.js`](../../services/orders/src/circuit-breaker.js), unit-tested with a fake clock in [`test/circuit-breaker.test.js`](../../services/orders/test/circuit-breaker.test.js).
- Trip thresholds: ≥ 50 % failures in the last 20 calls (at least 10 calls), or 5 consecutive failures.
  - The consecutive rule trips faster when the dependency dies suddenly. In E1 it decided both trips.
  - The rate rule catches a dependency that fails half the time.
- What counts as a failure: a timeout, a connection error or a 5xx. A 404 ("no such product") and other 4xx are answers, not failures.
- Reset timeout: 15 s open, then half-open with at most 3 trial calls. Calls beyond those 3 are rejected and get the fallback. One failed trial re-opens the breaker and restarts the 15 s.
- Every transition is logged (`orders: circuit catalog closed → open (5 consecutive failures)`) and counted (`circuit_breaker_transitions_total`). The current state is a gauge (`circuit_breaker_state`: 0 / 1 / 2).

### 4.2 Retry with exponential backoff and full jitter

- [`services/orders/src/retry.js`](../../services/orders/src/retry.js): `sleep = random(0, min(500 ms, 50 ms · 2^attempt))`, 3 attempts in total.
- Full jitter instead of a fixed backoff: when catalog recovers, the retries of all orders pods do not arrive in one synchronized wave.
- Retried: connection errors, 502/503/504, on the idempotent GET only.
- **Not** retried:
  - timeouts — a slow catalog would get twice the load, and the user would wait twice as long; that case is the breaker's;
  - `CircuitOpenError` — the breaker already decided;
  - 4xx.

### 4.3 Fallback and graceful degradation

| Situation | Before (orders 1.1.0) | After (orders 1.2.0) |
|---|---|---|
| catalog slow | waits 2 s, then **502** | waits ≤ 1 s, then **201** from the cache with `degraded: true`, `X-Degraded: timeout`; once the breaker is open: **201 in a few ms** (`X-Degraded: circuit_open`) |
| catalog unreachable, product seen before | **502** | **201** degraded |
| catalog unreachable, product never seen by this pod | **502** | **503** + `Retry-After: <seconds until half-open>` — a retryable status with a hint, instead of a generic error |
| unknown product (catalog answers 404) | 422 | 422 (an answer, not a failure: does not trip the breaker) |

### 4.4 Mesh rules: timeouts, safe retries, bulkhead

Rendered by the chart from `mesh.routes` and `mesh.trafficPolicy` ([`templates/mesh.yaml`](../../charts/shoplite/templates/mesh.yaml)). The live objects are in [`evidence/06`](evidence/06-deployed-resilience-config.txt).

```yaml
# VirtualService catalog (east-west) and every route of VirtualService shop-edge
timeout: 10s
retries:
  attempts: 1
  perTryTimeout: 5s
  retryOn: connect-failure,refused-stream   # the request never reached the app → safe for POST
# DestinationRule <service> — bulkhead per calling sidecar
trafficPolicy:
  connectionPool:
    tcp:  { connectTimeout: 1s }
    http: { http1MaxPendingRequests: 32, http2MaxRequests: 64, maxRetries: 3 }
  outlierDetection: { consecutive5xxErrors: 5, interval: 10s, baseEjectionTime: 30s, maxEjectionPercent: 50 }
```

Before this week, orders → catalog had no VirtualService (except during the canary), so Istio's *default* retry policy applied: 2 retries, also on 503. With the new app retry that would have been up to 3 × 3 = 9 requests per order to a struggling catalog. Now it is at most 3 × 2, and the mesh retries only connection failures ([ADR-W11-03](adr.md#adr-w11-03--mesh-retries-only-where-the-request-never-reached-the-app-bulkhead-per-caller)).

### 4.5 Rate limiter at the gateway

An `EnvoyFilter` adds Envoy's local rate limit filter to `shop-gateway`. It is a token bucket per gateway pod: 200 tokens, refilled with 100 per second ([`templates/resilience.yaml`](../../charts/shoplite/templates/resilience.yaml)). The probe [`scripts/ratelimit-probe.py`](../../scripts/ratelimit-probe.py) gave these results ([`evidence/04`](evidence/04-ratelimit-probe.txt)):

| Phase | Requests | 200 | 429 |
|---|---|---|---|
| Burst, 1000 requests in 1.3 s (≈ 770 req/s) | 1000 | 325 | 675 |
| Steady 50 req/s for 10 s (below the refill rate) | 500 | 500 | 0 |

- 325 = the 200 tokens in the bucket plus ~130 refilled during the 1.3 s.
- The 675 rejected requests were answered by the gateway itself (`server: istio-envoy`, `x-local-rate-limit: true`, `retry-after: 1`) and never reached catalog.

## 5. Chaos engineering setup

- **Platform.** Chaos Mesh 2.8.8 is installed by Argo CD as Application `chaos-mesh` in its own AppProject. It has 1 controller and one chaos-daemon per worker node, on the containerd runtime ([`evidence/05`](evidence/05-chaos-mesh-install.txt)).
- **Blast radius.** `enableFilterNamespace: true`, so only namespaces annotated `chaos-mesh.org/inject: enabled` (`shop-dev`, `shop-staging`) can be targeted. `shop-prod` has no annotation.
- **Experiments as code.** The YAML is in [`k8s/chaos/experiments/`](../../k8s/chaos/experiments/), validated in CI against the Chaos Mesh CRD schemas. Argo CD does not sync them, because an experiment must not be restarted by a sync.
- **Runner** — [`scripts/chaos-experiment.py`](../../scripts/chaos-experiment.py), run for all three by [`scripts/chaos-run-all.sh`](../../scripts/chaos-run-all.sh):
  1. steady load: an open model, so slow answers do not slow the load down, `POST /api/orders` at 10/s through the staging edge;
  2. baseline 60 s → `kubectl apply` the fault → chaos window → `kubectl delete` → recovery 60 s;
  3. records every second: codes, degraded answers, p50/p95/max;
  4. collects breaker transitions from the orders logs and counters from Prometheus;
  5. checks the hypothesis (PASS/FAIL) and draws the timeline.

E1_E2_E3_RESULTS

## 9. Reproduce

```bash
# Argo CD tracks week11-resilience (gitops/bootstrap/root.yaml): orders 1.2.0, mesh rules,
# rate limit, Chaos Mesh, alerts — all from git.
kubectl apply -f gitops/bootstrap/root.yaml
docker build -t shoplite/orders:1.2.0 services/orders && kind load docker-image shoplite/orders:1.2.0 --name shoplite
(cd services/orders && npm test)                          # 28 tests: breaker, retry, fallback, metrics
kubectl -n observability port-forward svc/prometheus 9090:9090 &
./scripts/chaos-run-all.sh                                # E1–E3 under load → docs/week11/evidence/e*/
./scripts/ratelimit-probe.py staging 1000 50              # burst → 429, steady → 200
./scripts/render-diagrams.sh                              # Mermaid → PNG/SVG
node scripts/report/build-report.js docs/week11           # this report as .docx
```

## 10. Limitations

- **One cluster, one laptop.** Latency numbers come from a kind cluster on a laptop with 100 % tracing, so they are relative, not production figures. The machine also went to sleep during one attempt at the rate-limit probe. That run was discarded: its timings were meaningless.
- **Per-pod state.** The breaker and the cache live in each orders pod. N replicas probe catalog N times per reset timeout, and a new pod starts with an empty cache. A shared cache (Redis) would fix the cold start, at the cost of a new dependency on the order path.
- **Degraded orders are not re-priced.** The `degraded` flag is in the response, the trace and a metric, but not in the orders table. A re-pricing job would need it there (Week 13 is about schema changes).
- **The rate limit is local.** It is per gateway pod, not per client: one abusive client uses up everyone's budget. A per-client limit needs a descriptor (e.g. by API key) or the global rate-limit service.
- **Not tested:** the bulkhead's overflow (E1 never filled 32 pending requests at 10 orders/s), postgres failure (F7), and chaos in prod (excluded on purpose).
