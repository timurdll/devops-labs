# Week 10 — Architecture Decision Records

## ADR-W10-01 · Istio in sidecar mode, installed by Argo CD from the official Helm charts

**Status:** accepted

**Context:**
- The lab asks for decentralized traffic management, zero-trust transport (mTLS) and the *Envoy sidecar proxy* pattern, configured through Istio custom resources (VirtualService, DestinationRule, Gateway, PeerAuthentication) and checked with `istioctl`.
- The platform from Weeks 8–9 runs on a 3-node kind cluster with 7.6 GiB in total.
- Every change must arrive through git and Argo CD, and prod must stay behind its manual approval gate.

**Options considered**
| Option | For | Against |
|---|---|---|
| **Istio, sidecar mode** | The pattern the lab names. L7 policy (routes, retries, RBAC by HTTP method) lives in every pod's Envoy. Mature `istioctl` diagnostics (`proxy-config`, `x describe`, `x authz check`). | One Envoy per pod: memory, an extra hop per side, and an injection step in the pod lifecycle. |
| Istio, ambient mode (ztunnel + waypoint) | No per-pod proxy. Lower memory. | No sidecar to study. L7 features only through extra waypoint proxies. Different debugging model. |
| Linkerd | Light Rust micro-proxy, simple mTLS. | Not Envoy, and does not use the Istio CRDs the lab asks for. |

**Decision**
- Istio **1.31.4**, sidecar mode. The patch version is pinned in all three charts so that `base`, `cni` and `istiod` can never skew.
- Installed from the official charts (`blob.istio.io/istio-release/charts`) as four Argo CD Applications in an `AppProject mesh`, ordered by sync waves:
  - `istio-base` (−3): CRDs and the validating webhook;
  - `istio-cni` and `istiod` (−2);
  - `mesh-config` (−1): `k8s/mesh`, the mesh-wide PeerAuthentication and Telemetry.
- Only differences from the chart defaults live in git ([`k8s/mesh/istiod-values.yaml`](../../k8s/mesh/istiod-values.yaml)):
  - sidecar requests 10m / 40Mi;
  - one istiod replica;
  - `outboundTrafficPolicy: REGISTRY_ONLY`;
  - `holdApplicationUntilProxyStarts`;
  - the OpenTelemetry extension provider.
- Sidecars run as **native sidecars** (an init container with `restartPolicy: Always`, the default since 1.27). They start before the app and stop after it. The canary pod showed the order `istio-validation` → `istio-proxy` (startup probe) → `catalog`.

**Consequences**
- Measured cost ([`evidence/11-sidecar-overhead.txt`](evidence/11-sidecar-overhead.txt)):
  - 16 proxies use **616 MiB** working set (34–52 MiB each);
  - the 14 meshed app containers use 473 MiB;
  - so on this platform the data plane costs more memory than the apps it protects. Ambient mode is the lever if that matters later.
- Latency: one request crosses three Envoys (gateway, orders, catalog). In the recorded trace ([`evidence/08`](evidence/08-trace-through-mesh.txt)), the orders → catalog hop takes 31 ms as seen by the orders sidecar, against 19.5 ms inside catalog. That is a kind cluster with 100 % tracing; the absolute numbers are not production figures.
- Argo CD's app-of-apps only waits for a wave when it knows the health of an `Application`. Argo CD ≥ 1.8 removed that health check, so it was restored in [`gitops/argocd/argocd-cm.yaml`](../../gitops/argocd/argocd-cm.yaml). Without it, `istiod` could start before the CRDs exist.

## ADR-W10-02 · One Envoy ingress gateway per environment, behind Traefik

**Status:** accepted

**Context:** North-south traffic already enters through Traefik (Weeks 7–9: hosts `<env>.shop.local`, edge metrics and the trace root). A mesh needs an Envoy at the edge so that the first hop into the mesh is mTLS and is routed by a VirtualService.

**Decision**
- Each environment namespace gets its own gateway: a Deployment `shop-gateway` that istiod's `gateway` injection template turns into Envoy (`image: auto`), plus a `Gateway` (port 80) and a `VirtualService shop-edge`.
- Traefik keeps the host and TLS role and sends **the whole host** to `shop-gateway:80`. All path routing moved from the Ingress to `shop-edge`.
- `PILOT_SCOPE_GATEWAY_TO_NAMESPACE=true`: a `Gateway` selects gateway pods in its own namespace only.

**Why**
- Blast radius and approval: prod's gateway config changes only with prod's approved sync, never with a dev commit.
- Without namespace scoping, the selector `istio: shop-gateway` of dev's Gateway would also program the gateway pods of staging and prod. That would merge the host tables across environments.
- Keeping Traefik avoids touching DNS, ports and the Week 9 edge telemetry. Envoy continues the `traceparent` Traefik starts.

**Consequences**
- Two proxies at the edge (Traefik → Envoy), which costs one extra hop.
- NetworkPolicy now lets the ingress controller reach **only** `shop-gateway`. The services accept traffic from the gateway and from their real callers.
- `istioctl analyze` found two real misconfigurations in the first version, and both were fixed in chart 0.3.0:
  - IST0162: the Gateway port was not exposed by the Service. The Gateway now listens on 80, and the Service maps 80 → targetPort 8080.
  - IST0144: UID 1337 was set at pod level. It is now set on the container only.

## ADR-W10-03 · istio-cni instead of the `istio-init` container

**Status:** accepted

**Context:** The default sidecar injection adds an `istio-init` container with `NET_ADMIN` and `NET_RAW` to write the iptables redirect. All application namespaces enforce Pod Security **restricted** (Week 7), which forbids those capabilities.

**Decision:**
- The `istio-cni` DaemonSet writes the redirect when the pod's network is set up: outbound to :15001, inbound to :15006.
- The pod keeps only an unprivileged `istio-validation` init container, which checks that the redirect works.
- `istio-system` is labelled PSA **privileged**, because the node agent needs hostPath access to the CNI configuration. Both the label and the exception are recorded in git ([`gitops/apps/mesh.yaml`](../../gitops/apps/mesh.yaml)).

**Consequences**
- Application namespaces stay `restricted` with no exceptions ([`evidence/02`](evidence/02-rollout-phases.txt)).
- The privileged component is a single DaemonSet in a namespace that only the `mesh` AppProject can deploy to.

## ADR-W10-04 · Phased rollout: PERMISSIVE → STRICT → canary; prod stays at phase 1 until approved

**Status:** accepted

**Context:** Switching mTLS to STRICT while some callers are not yet meshed breaks them with connection resets. The rollout has to be observable and reversible at each step.

**Decision:** Each phase is a commit:

| Phase | `mesh.*` values | Who |
|---|---|---|
| 0 | control plane only, chart `mesh.enabled: false` | all (commit 894da3c) |
| 1 | sidecars + gateway, `mtlsMode: PERMISSIVE`, `authorization: false` | dev, staging (128048e); **prod in git, waiting for approval** |
| 2 | `mtlsMode: STRICT`, `authorization: true` | dev, staging (5a17706) |
| 3 | catalog 1.2.0 canary, 10 % | staging (d6be3fc) |

- The mesh-wide PeerAuthentication in `k8s/mesh` is **STRICT**, so a namespace without its own policy is secure by default. During phase 1 the chart overrides it per namespace with PERMISSIVE.
- Injection happens at pod creation, so phase 1 is the only phase that re-creates pods (a rolling update with PDBs in place). Phases 2 and 3 change only Istio resources: phase 1 → 2 reached both environments through xDS in about 40 s, with no pod restarts.
- The control plane (phase 0) shipped one commit before the workloads. A pod created before the injector webhook exists would silently stay outside the mesh.

**Evidence**
- PERMISSIVE: a plaintext GET from an orders pod (bypassing its sidecar as UID 1337) is readable on the wire and returns 200 ([`evidence/03`](evidence/03-mtls-capture-permissive.txt)).
- STRICT: the same request gets a TCP RST from the catalog sidecar, `curl: (56)` ([`evidence/04`](evidence/04-mtls-capture-strict.txt)). Meshed traffic is TLS (ClientHello with Istio's SNI and ALPN, then application data) in both captures.

**Consequences:**
- prod is `OutOfSync` with phase 1 in git and waits for a manual `scripts/gitops-sync-prod.sh` by the operator.
- In this session the prod sync was not approved, so prod runs without the mesh. Phases 2 and 3 for prod are separate later commits, each behind the same gate.

## ADR-W10-05 · Zero trust as two independent layers: NetworkPolicy (labels) + AuthorizationPolicy (identity)

**Status:** accepted

**Context:** Week 7 NetworkPolicies allow traffic by **pod label**. Anyone who can create a pod in the namespace can set any label, so labels are a claim, not an identity.

**Decision**
- Each workload gets its own ServiceAccount (`automountServiceAccountToken: false`; the sidecar uses its own projected token). That gives each workload a SPIFFE ID `spiffe://cluster.local/ns/<ns>/sa/<sa>` in its istiod-signed certificate.
- AuthorizationPolicies per namespace:
  - `default-deny` (`spec: {}`);
  - one ALLOW per edge of the call graph, matched on `source.principals`:
    - gateway → web, orders, catalog;
    - orders → catalog;
    - catalog and orders → postgres (TCP).
- NetworkPolicies stay in place (defence in depth: L3/L4 in the CNI, identity in Envoy).
- `outboundTrafficPolicy: REGISTRY_ONLY`: a sidecar routes only to hosts known to the mesh, so a compromised app cannot reach arbitrary hosts through its proxy.

**Evidence** ([`evidence/05`](evidence/05-authz-identity-probe.txt)):
- An "impostor" pod labelled `app.kubernetes.io/name=orders` passes NetworkPolicy but runs as `sa/default`. Its requests are refused with **403 `RBAC: access denied`**.
- The real orders identity gets 200.
- `istioctl x authz check` and the RBAC counters show the decision inside catalog's sidecar.
- Metrics by `source_principal` ([`evidence/07`](evidence/07-istioctl-diagnostics.txt)): every request to catalog is `mutual_tls` from `sa/shop-gateway` or `sa/orders`, plus one 403 from `sa/default`.

**Consequences**
- Every new call-graph edge needs an AuthorizationPolicy change. The chart derives the policies from `services.*`, so the policy and the dependency it allows are reviewed together.
- Exemption for observability: the Collector is not meshed and scrapes istio-agent on :15020, which is not under mTLS (ADR-W10-07).

## ADR-W10-06 · Canary by weights in the VirtualService, not by replica count

**Status:** accepted

**Context:**
- The Week 8 approach (two Deployments behind one Service) splits traffic by the ratio of ready pods, so 10 % needs a 9:1 replica ratio and changes whenever a pod restarts.
- The lab asks for an explicit 90 / 10 split.

**Decision**
- The chart renders a second Deployment `catalog-v2` (label `version: v2`, image 1.2.0, 1 replica) next to `catalog` (v1, 1.1.0, 2 replicas).
- `DestinationRule catalog` defines subsets v1 and v2.
- The weights are 90 / 10 and come from `services.catalog.canary.weight`. They apply in **two** places:
  - `VirtualService shop-edge` (gateway → catalog, browser and API traffic);
  - `VirtualService catalog` bound to `mesh` (orders → catalog, east-west).
- DestinationRule settings: `connectTimeout 1s` and `outlierDetection` (5 consecutive 5xx → eject for 30 s, at most 50 %).

**Evidence** ([`evidence/06`](evidence/06-canary-traffic-split.txt)): three independent counts for N = 1000 requests.

| Source | Result |
|---|---|
| Client side | v2 answered **119 / 1000 = 11.9 %** (95 % Wilson interval 10.0–14.1 %). v1 ignores `?q=` and returns everything; v2 searches and returns `[]`, so the client sees which version answered. |
| Gateway access log | 881 to `outbound\|80\|v1\|catalog…`, 119 to `…\|v2\|…` |
| Envoy metrics in Prometheus | gateway → catalog 11.9 % v2; orders → catalog **9.5 %** v2; all `mutual_tls` |

The 1.9-point deviation at the edge is within sampling noise for N = 1000: Envoy picks a cluster per request at random by weight.

**Consequences:** Promotion and rollback are value changes, which are commits:
- promote: `weight: 50`, then `100`, then make 1.2.0 the stable `image.tag`;
- roll back: `canary.enabled: false`.

Argo CD applies each one and istiod pushes it to the proxies in seconds. Pods do not restart.

## ADR-W10-07 · Mesh telemetry goes into the Week 9 pipeline

**Status:** accepted

**Context:** Week 9's Collector scraped `:8080/metrics` on app pods. Under STRICT, a plaintext scrape of :8080 is rejected (the same RST as in evidence 04).

**Decision**
- **Metrics merging:** istio-agent serves the app's own metrics *and* Envoy's `istio_*` metrics on `:15020/stats/prometheus`, and rewrites the pod's `prometheus.io/port` annotation to 15020.
- The Collector's scrape config builds the target from **pod IP + annotated port**, not from the declared container ports. NetworkPolicy `allow-telemetry-scrape` opens 15020 (meshed) or 8080 (not meshed) to the Collector only.
- **Tracing:** a `Telemetry` resource sends Envoy spans (100 %) to the Collector at `:4317` through the `otel-collector` extension provider. Envoy continues the W3C `traceparent`, so gateway and sidecar spans join the app spans in one trace ([`evidence/08`](evidence/08-trace-through-mesh.txt), [diagram](diagrams/trace-waterfall-mesh.png)).
- Access logs are turned on for the gateway only (`Telemetry gateway-access-log`). They are the second independent count in the canary check.

**Consequences**
- The Week 9 dashboards, exemplars and alerts keep working unchanged: 51/53 Week 9 checks pass with the mesh in place ([`evidence/10`](evidence/10-week9-telemetry-regression.txt)). The two failures are prod waiting for approval and a panel that needs errors.
- One Week 9 check was rewritten: meshed `web` pods are now scraped, for Envoy metrics only, so the check asserts the actual intent instead ("no app-level RED series from nginx").
- Queries must use `destination_canonical_service="catalog"`. `destination_workload` is `catalog` or `catalog-v2`, which would hide the canary.
- Envoy's TLS handshake counters are not exported by Istio's default stats matcher. mTLS is shown through `connection_security_policy="mutual_tls"` on `istio_requests_total` instead.
