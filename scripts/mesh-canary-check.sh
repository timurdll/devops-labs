#!/usr/bin/env bash
# Week 10 — does the mesh split traffic the way the VirtualServices say? Three independent counts:
#   1. client side   N × GET /api/catalog/products?q=<no-match> through Traefik → gateway.
#                    v1 (1.1.0) ignores q and lists every product, v2 (1.2.0) searches → [];
#                    servedBy names the pod. A user-visible behaviour difference, not a header.
#   2. gateway side  the gateway's Envoy access log: upstream cluster outbound|80|<subset>|catalog…
#   3. mesh side     Envoy metrics in Prometheus (istio_requests_total by destination_version), for
#                    gateway → catalog AND orders → catalog (east-west, driven by M orders).
# Usage: scripts/mesh-canary-check.sh <env> [N=1000] [M=200]   (Prometheus port-forwarded on :9090)
set -euo pipefail
env=${1:?usage: $0 <env> [N] [M]}; n=${2:-1000}; m=${3:-200}; ns=shop-$env
host="Host: $env.shop.local"; prom=${PROM:-http://127.0.0.1:9090}
export PATH="${ISTIOCTL_DIR:-}:$PATH"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "# $(date -u +%FT%TZ)  namespace $ns"
echo; echo "## desired state (git → Argo CD → istiod)"
kubectl -n "$ns" get virtualservice catalog -o jsonpath='{range .spec.http[0].route[*]}  VirtualService catalog (mesh):       subset {.destination.subset} weight {.weight}{"\n"}{end}'
kubectl -n "$ns" get virtualservice shop-edge -o jsonpath='{range .spec.http[?(@.name=="catalog")].route[*]}  VirtualService shop-edge (gateway):  subset {.destination.subset} weight {.weight}{"\n"}{end}'
kubectl -n "$ns" get deploy -l app.kubernetes.io/name=catalog -o custom-columns='  DEPLOYMENT:.metadata.name,VERSION:.spec.template.metadata.labels.version,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas'
gw=$(kubectl -n "$ns" get pod -l app.kubernetes.io/name=shop-gateway -o jsonpath='{.items[0].metadata.name}')
echo; echo "## what istiod pushed to the gateway (istioctl proxy-config route $gw)"
istioctl proxy-config route "$gw.$ns" --name http.8080 -o json > "$tmp/route.json"
python3 - "$tmp/route.json" <<'PY'
import json, sys
for rc in json.load(open(sys.argv[1])):
    for vh in rc["virtualHosts"]:
        for r in vh["routes"]:
            wc = r.get("route", {}).get("weightedClusters")
            if wc:
                print("  ", r["match"].get("prefix"), "→", ", ".join("%s = %s" % (c["name"], c["weight"]) for c in wc["clusters"]))
PY

start=$(date -u +%s); since=$(date -u +%FT%TZ)
echo; echo "## 1. client side: $n × GET /api/catalog/products?q=zzz-canary-probe (16 in parallel)"
seq "$n" | xargs -P 16 -I{} curl -s -H "$host" "http://127.0.0.1:8080/api/catalog/products?q=zzz-canary-probe" -o "$tmp/resp-{}.json" -w "%{http_code}\n" > "$tmp/codes"
echo "  HTTP codes: $(sort "$tmp/codes" | uniq -c | xargs)"
python3 - "$tmp" "$n" <<'PY'
import glob, json, math, sys
tmp, n = sys.argv[1], int(sys.argv[2])
v1 = v2 = bad = 0; pods = {}
for f in glob.glob(f"{tmp}/resp-*.json"):
    try: d = json.load(open(f))
    except Exception: bad += 1; continue
    pod = d.get("servedBy", "?"); pods[pod] = pods.get(pod, 0) + 1
    if pod.startswith("catalog-v2-"):
        v2 += 1; assert d["items"] == [] and d.get("query") == "zzz-canary-probe", "v2 must search"
    else:
        v1 += 1; assert len(d["items"]) > 0 and "query" not in d, "v1 ignores q"
tot = v1 + v2; p = v2 / tot; z = 1.96
lo = (p + z*z/(2*tot) - z*math.sqrt(p*(1-p)/tot + z*z/(4*tot*tot))) / (1 + z*z/tot)
hi = (p + z*z/(2*tot) + z*math.sqrt(p*(1-p)/tot + z*z/(4*tot*tot))) / (1 + z*z/tot)
print(f"  v1 (all products, no search): {v1}   v2 (search → []): {v2}   unparsable: {bad}")
print(f"  canary share {p:.1%}  (95 % Wilson interval {lo:.1%} – {hi:.1%}; target 10 %)")
for pod, c in sorted(pods.items()): print(f"    {pod:<34} {c}")
PY

echo; echo "## 2. gateway access log since $since (upstream cluster per request)"
sleep 3 # Envoy flushes its access log every second
kubectl -n "$ns" logs -l app.kubernetes.io/name=shop-gateway --since-time="$since" --tail=-1 2>/dev/null \
  | grep -o 'outbound|80|v[0-9]*|catalog[^ "]*' | sort | uniq -c | sed 's/^/  /'
echo "  sample line:"; kubectl -n "$ns" logs -l app.kubernetes.io/name=shop-gateway --since-time="$since" --tail=-1 2>/dev/null | { grep 'q=zzz' | grep '|v2|' || true; } | sed -n '1s/^/    /p' | cut -c1-400

echo; echo "## 3. east-west: $m × POST /api/orders (each one: orders → catalog GET /products/:id)"
seq "$m" | xargs -P 8 -I{} curl -s -o /dev/null -w "%{http_code}\n" -H "$host" -H 'Content-Type: application/json' \
  -d '{"productId":1,"quantity":1}' http://127.0.0.1:8080/api/orders | sort | uniq -c | sed 's/^/  HTTP /'
echo "  (waiting 35 s: two scrape intervals)"; sleep 35
win=$(( $(date -u +%s) - start + 15 ))
echo; echo "## Envoy metrics (Prometheus): requests to catalog in the last ${win}s, reported by the catalog sidecars"
echo "  (destination_canonical_service=catalog covers both Deployments; destination_workload would be catalog / catalog-v2)"
curl -s "$prom/api/v1/query" --data-urlencode "query=sum by (source_workload, destination_version, connection_security_policy) (increase(istio_requests_total{reporter=\"destination\", namespace=\"$ns\", destination_canonical_service=\"catalog\"}[${win}s])) > 0" > "$tmp/prom.json"
python3 - "$tmp/prom.json" <<'PY'
import json, sys
rows = {}
for x in json.load(open(sys.argv[1]))["data"]["result"]:
    m, v = x["metric"], float(x["value"][1])
    rows.setdefault(m["source_workload"], {})[m["destination_version"]] = v
    print("  %13s → catalog %s  %8.0f   %s" % (m["source_workload"], m["destination_version"], v, m["connection_security_policy"]))
for src, v in rows.items():
    tot = sum(v.values()) or 1
    print("  %13s: canary share %.1f%% of %.0f" % (src, 100 * v.get("v2", 0) / tot, tot))
PY
