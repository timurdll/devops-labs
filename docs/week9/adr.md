# Week 9 — Architecture Decision Records

## ADR-W9-01 · OpenTelemetry for traces, Prometheus exposition for metrics

**Status:** accepted

**Context:** The lab requires RED metrics through "the Prometheus client SDK (`/metrics`)" and distributed tracing through "OpenTelemetry tracing headers". The OTel SDK can also produce metrics, so in principle one SDK could do both.

**Decision**
- **Metrics:** `prom-client` 15 registry per service, served on `GET /metrics` in OpenMetrics format.
- **Traces:** OpenTelemetry Node SDK with auto-instrumentation for `http` (server), `undici` (`fetch` to catalog) and `pg`, exported over OTLP/HTTP. Context crosses process boundaries in the W3C `traceparent` header.
- **Linking the two:** every duration observation carries the active span's `trace_id` as an **exemplar**.

**Why**
- Pull-based `/metrics` works without any backend: `curl` shows the raw counters, which made testing and debugging trivial.
- Metric and label names follow the OTel HTTP semantic conventions (`http_server_request_duration_seconds{http_request_method,http_route,http_response_status_code}`), so a later move to OTLP metrics keeps the same dashboard queries.
- Exemplars are what make "metrics → traces" a single click instead of a time-range search.

**Consequences**
- Two libraries per service instead of one.
- The route template is computed by the app (`routeOf()`), because raw paths such as `/api/catalog/products/17` would create one time series per product id (unbounded cardinality). Unknown paths collapse into `http_route="unmatched"`.

## ADR-W9-02 · One Collector as the telemetry gateway

**Status:** accepted

**Context:** Apps could export straight to Jaeger, and Prometheus could scrape pods itself.

**Decision:** All telemetry goes through one OpenTelemetry Collector (contrib 0.163):
- It receives OTLP spans from the apps and Traefik.
- It scrapes every pod annotated `prometheus.io/scrape=true`.
- It enriches spans with Kubernetes metadata (`k8s_attributes`).
- It exports spans to Jaeger and metrics to Prometheus (remote write).

**Why**
- **Decoupling:** apps know exactly one address (`OTEL_EXPORTER_OTLP_ENDPOINT`). Changing a backend, for example Jaeger → Tempo, is one Collector config change, not a redeploy of every service.
- **Policy in one place:** the Collector runs `memory_limiter` (refuses data instead of being OOM-killed), batching and attribute enrichment, and is the place for future tail sampling or PII scrubbing.
- **One scraper:** Prometheus is a pure store with no Kubernetes RBAC. Only the Collector's ServiceAccount can list pods.

**Consequences**
- The Collector is a single point of failure for *telemetry*, not for traffic: the SDK drops spans when the Collector is unreachable, and requests are never blocked.
- See ADR-W9-03 for why it runs as a single replica.

## ADR-W9-03 · Collector: Deployment with one replica (no DaemonSet, no HA yet)

**Status:** accepted for the lab

The prometheus receiver has no built-in sharding: two replicas would scrape every target twice and write duplicate samples. With 3 environments × ~3 pods plus 2 Traefik pods, one replica scraping every 15 s uses about 30 m CPU.

**Production path**
- **OpenTelemetry Operator with the Target Allocator** to shard scrape targets across N Collector replicas.
- **A DaemonSet "agent" tier** (node-local OTLP endpoint, `k8s_attributes` by node), forwarding to a gateway Deployment that does tail sampling.

## ADR-W9-04 · Storage backends: Prometheus (remote-write receiver) and Jaeger (in-memory)

**Status:** accepted for the lab

| Concern | Lab choice | Production choice |
|---|---|---|
| Metrics store | Prometheus v3, emptyDir, 3 d retention, `--web.enable-remote-write-receiver`, `--enable-feature=exemplar-storage` | Prometheus with a PVC + Thanos/Mimir for HA and long-term retention |
| Trace store | Jaeger v2 all-in-one, memory store (20 000 traces) | Jaeger with Badger/OpenSearch/ClickHouse, or Grafana Tempo on object storage |
| Collector → backend transport | plaintext inside the cluster, restricted by NetworkPolicy | mTLS (cert-manager or a service mesh) |
| Grafana auth | local admin, password in a Secret that is **not in git**; no anonymous access, no Ingress (port-forward only) | SSO (OIDC), viewer role by default |

The RED SLOs live next to the data as **Prometheus recording and alert rules** (`ShopLiteHighErrorRate` above 5 % for 1 min, `ShopLiteSlowRequests` with p95 above 500 ms for 2 min). There is no Alertmanager in the lab: firing alerts are read from `/api/v1/alerts`.

## ADR-W9-05 · Jaeger pinned to 2.20.0 (finding from the rollout)

**Status:** accepted, revisit when upstream is fixed

**Context:** The stack was first rolled out with Jaeger **2.22.0**. Spans arrived, and the Jaeger UI and `/api/v3/*` worked. However, the Grafana *Jaeger* data source (Grafana 13.2.5, plugin 13.0.5) reported `request failed: 404 Not Found` for the health check, the service picker and the search. A logging proxy placed between Grafana and Jaeger showed the plugin calling `/api/services` and `/api/traces?service=…`. Those are the legacy query routes. Upstream issues place their removal in 2.21; I verified them present in 2.20.0 and absent in 2.22.0. Grafana's feature toggle `jaegerEnableGrpcEndpoint` moves services and operations to `/api/v3`, but **search** still uses `/api/traces` (tracked upstream as [grafana/grafana-jaeger-datasource#87](https://github.com/grafana/grafana-jaeger-datasource/issues/87)).

**Options**

| Option | Verdict |
|---|---|
| Keep 2.22, link Grafana to the Jaeger UI only by URL | ✗ No trace panels or exemplar → trace view inside Grafana. That loses half of the dashboard design. |
| Replace Jaeger with Tempo | ✗ The lab specifies Jaeger, and it is a bigger change than the problem. |
| **Pin Jaeger 2.20.0**, the last release with the legacy routes | ✓ Verified locally (Grafana 13.2.5 + Jaeger 2.20.0: health OK, search 200) before the commit. Same configuration file, same OTLP ingest. |

**Consequences:** The pin is documented in `k8s/observability/jaeger.yaml`. Move back to the latest 2.x once the plugin speaks `/api/v3` for search.

## ADR-W9-06 · Sampling: 100 % head sampling, decided at the edge

**Status:** accepted for the lab

Traefik starts the trace and makes the sampling decision (`--tracing.sampleRate=1.0`). The services use `parentbased_traceidratio`, so they follow the sampled flag in `traceparent` (`…-01` = sampled). `telemetry.samplingRatio` therefore only affects traces that *start* in a service, such as requests that bypass the ingress.

Metrics are not sampled: RED numbers always count 100 % of the requests. That is why the dashboard's numbers come from metrics, and traces only explain individual requests.

**Production:** lower the edge rate (for example 10 %), or keep 100 % at the edge and add `tail_sampling` in the Collector with these policies: keep all errors, keep everything slower than the SLO, keep 5 % of the rest.

## ADR-W9-07 · Traefik's RBAC: per-namespace Roles (fixes a Week 8 finding)

**Status:** accepted

Week 8 granted Traefik read access to the environment namespaces with one ClusterRole bound by three RoleBindings. The effective scope was namespaced, but a ClusterRole that can read Secrets is one ClusterRoleBinding away from cluster-wide Secret access. Trivy reports this as **KSV-0041 (CRITICAL)**. It had not shown up because the Week 8 branch never ran the CI workflow.

Week 9 replaced it with a namespaced **Role + RoleBinding per environment**. The old objects were pruned with a targeted, manual `argocd app sync platform --prune --resource …` (evidence `02-platform-prune-rbac.txt`), because the platform app intentionally has auto-prune off (ADR-W8-04).
