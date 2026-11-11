#!/usr/bin/env bash
# Week 10 — istioctl diagnostics of one environment: is every proxy in sync with istiod, is the
# configuration valid, and what did istiod actually program into Envoy (routes with weights,
# subsets, mTLS origination with the expected SPIFFE ID, inbound mTLS requirement, certificates,
# authorization)? Read-only.
# Usage: scripts/mesh-diagnose.sh <env>      (istioctl on PATH, or ISTIOCTL_DIR=<dir>)
set -euo pipefail
env=${1:?usage: $0 <dev|staging|prod>}; ns=shop-$env
export PATH="${ISTIOCTL_DIR:-}:$PATH"
pod() { kubectl -n "$ns" get pod -l "$1" -o jsonpath='{.items[0].metadata.name}'; }
v1=$(pod app.kubernetes.io/name=catalog,version=v1); od=$(pod app.kubernetes.io/name=orders); gw=$(pod app.kubernetes.io/name=shop-gateway)
v2=$(kubectl -n "$ns" get pod -l app.kubernetes.io/name=catalog,version=v2 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
run() { echo; echo "\$ $*"; "$@" 2>&1; }

echo "# $(date -u +%FT%TZ)  namespace $ns  PeerAuthentication $(kubectl -n "$ns" get peerauthentication default -o jsonpath='{.spec.mtls.mode}')"
run istioctl version
run istioctl proxy-status
run istioctl analyze -n "$ns"
for d in catalog orders web shop-gateway; do run istioctl x check-inject "deployment/$d" -n "$ns"; done
[ -n "$v2" ] && run istioctl x describe pod "$v2.$ns"
run istioctl proxy-config cluster "$od.$ns" --fqdn "catalog.$ns.svc.cluster.local"

echo; echo "# orders → catalog: client-side TLS that istiod programmed (UpstreamTlsContext per subset)"
istioctl proxy-config cluster "$od.$ns" --fqdn "catalog.$ns.svc.cluster.local" -o json | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    t = c.get("transportSocket", {}).get("typedConfig", {}); ctx = t.get("commonTlsContext", {})
    sans = [m.get("exact") for m in ctx.get("combinedValidationContext", {}).get("defaultValidationContext", {}).get("matchSubjectAltNames", [])]
    print("  %s\n    SNI %s | ALPN %s | peer must be %s | own cert: SDS %s | TLS %s-%s\n    connectTimeout %s | outlierDetection %s" % (
        c["name"], t.get("sni"), ctx.get("alpnProtocols"), sans, [s["name"] for s in ctx.get("tlsCertificateSdsSecretConfigs", [])],
        ctx.get("tlsParams", {}).get("tlsMinimumProtocolVersion"), ctx.get("tlsParams", {}).get("tlsMaximumProtocolVersion"),
        c.get("connectTimeout"), json.dumps(c.get("outlierDetection"))))'

for c in $(kubectl -n "$ns" get destinationrule catalog -o jsonpath='{range .spec.subsets[*]}outbound|80|{.name}|catalog.'"$ns"'.svc.cluster.local {end}'); do
  run istioctl proxy-config endpoint "$od.$ns" --cluster "$c"
done

run istioctl proxy-config secret "$v1.$ns"
echo; echo "# workload certificate of $v1 (signed by istiod's CA, rotated before it expires; SPIFFE ID in the SAN)"
istioctl proxy-config secret "$v1.$ns" -o json | python3 -c '
import base64, json, subprocess, sys
d = json.load(sys.stdin)["dynamicActiveSecrets"]
pem = base64.b64decode([s for s in d if s["name"] == "default"][0]["secret"]["tlsCertificate"]["certificateChain"]["inlineBytes"])
txt = subprocess.run(["openssl", "x509", "-noout", "-text"], input=pem, capture_output=True).stdout.decode()
keys = ["Issuer:", "Not Before", "Not After", "URI:", "Public Key Algorithm", "Signature Algorithm"]
seen = set()
for l in txt.splitlines():
    k = next((k for k in keys if k in l), None)
    if k and k not in seen: seen.add(k); print("  " + l.strip())'

echo; echo "# inbound listener of $v1 (virtualInbound :15006): filter chains for destination port 8080"
istioctl proxy-config listener "$v1.$ns" --port 15006 -o json | python3 -c '
import json, sys
for l in json.load(sys.stdin):
    for fc in l.get("filterChains", []):
        m = fc.get("filterChainMatch", {})
        if m.get("destinationPort") != 8080: continue
        ts = fc.get("transportSocket", {}).get("typedConfig", {})
        print("  transport %-6s ALPN %-40s requireClientCertificate %s" % (m.get("transportProtocol", "(any)"), m.get("applicationProtocols"), ts.get("requireClientCertificate")))'
echo "  (STRICT: only TLS chains exist for :8080 — a plaintext connection matches no chain and is reset)"

run istioctl proxy-config route "$gw.$ns" --name http.8080
run istioctl x authz check "$v1.$ns"

echo; echo "# what the catalog sidecar reports per request (its own /stats/prometheus): peer identity + mTLS"
kubectl -n "$ns" exec "$v1" -c istio-proxy -- pilot-agent request GET stats/prometheus 2>/dev/null \
  | grep '^istio_requests_total{' | grep 'reporter="destination"' \
  | sed -E 's/.*source_principal="([^"]*)".*response_code="([^"]*)".*connection_security_policy="([^"]*)".*\} ([0-9]+)/\1 \2 \3 \4/; s/.*connection_security_policy="([^"]*)".*source_principal="([^"]*)".*response_code="([^"]*)".*\} ([0-9]+)/\2 \3 \1 \4/' \
  | awk '{printf "  %-55s code %-4s %-11s %s requests\n", $1, $2, $3, $4}' | sort | uniq
