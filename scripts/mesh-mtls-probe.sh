#!/usr/bin/env bash
# Week 10 — what actually crosses the wire to catalog, observed from outside the pod.
#
#   1. tcpdump in the network namespace of one catalog pod (eth0, port 8080), run from a throwaway
#      privileged container that joins the kind node's PID namespace — nothing is added to the
#      cluster or to the pod.
#   2. While it captures:
#        a) GET /api/catalog/products through Traefik → gateway → catalog   (mesh, mTLS)
#        b) POST /api/orders → orders → catalog                             (mesh, mTLS)
#        c) a PLAINTEXT GET from inside an orders pod: an ephemeral curl container running as
#           UID 1337, the UID Istio's redirection rules exempt (Envoy's own UID). NetworkPolicy
#           allows it (it comes from an orders pod); only PeerAuthentication decides.
#   Under PERMISSIVE, (c) succeeds and its HTTP request is readable in the capture. Under STRICT the
#   catalog sidecar rejects it. (a) and (b) are TLS records either way.
#
# Usage: scripts/mesh-mtls-probe.sh <env> [seconds]
set -euo pipefail
env=${1:?usage: $0 <dev|staging|prod> [seconds]}; secs=${2:-12}
ns=shop-$env
CURL_IMAGE=curlimages/curl:8.17.0@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40
CAPTURE_IMAGE=alpine:3.22

pod=$(kubectl -n "$ns" get pod -l app.kubernetes.io/name=catalog,version=v1 -o jsonpath='{.items[0].metadata.name}')
node=$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.spec.nodeName}')
ip=$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.podIP}')
podid=$(docker exec "$node" crictl pods --name "^$pod\$" -q)
cid=$(docker exec "$node" crictl ps --pod "$podid" --name '^catalog$' -q)
pid=$(docker exec "$node" crictl inspect -o go-template --template '{{.info.pid}}' "$cid")
mode=$(kubectl -n "$ns" get peerauthentication default -o jsonpath='{.spec.mtls.mode}')
echo "# $(date -u +%FT%TZ)  namespace $ns  PeerAuthentication default: $mode"
echo "# capture: pod $pod ($ip) on $node, netns of PID $pid, tcp port 8080, ${secs}s"

out=$(mktemp); trap 'rm -f "$out"' EXIT
docker run --rm --privileged --pid="container:$node" "$CAPTURE_IMAGE" sh -c \
  "apk add -q tcpdump util-linux >/dev/null && timeout $secs nsenter -t $pid -n tcpdump -i eth0 -nn -l -x -s 1500 'tcp port 8080' 2>&1" > "$out" &
cap=$!
until grep -q "listening on" "$out" 2>/dev/null; do sleep 1; done

echo; echo "## a) edge request through the gateway (Traefik → shop-gateway → catalog)"
# 30 parallel requests: more than the gateway's idle pooled connections, so Envoy has to open new
# ones — and every new sidecar-to-sidecar connection starts with a TLS handshake.
seq 30 | xargs -P 30 -I{} curl -s -o /dev/null -w "%{http_code}\n" -H "Host: $env.shop.local" http://127.0.0.1:8080/api/catalog/products \
  | sort | uniq -c | sed 's/^ */  GET \/api\/catalog\/products × /; s/ \([0-9]*\)$/ → \1/'
echo; echo "## b) east-west: POST /api/orders (orders → catalog)"
curl -s -o /dev/null -w "POST /api/orders → %{http_code}\n" -H "Host: $env.shop.local" -H 'Content-Type: application/json' -d '{"productId":1,"quantity":1}' http://127.0.0.1:8080/api/orders
echo; echo "## c) plaintext from an orders pod, bypassing its sidecar (UID 1337)"
orders=$(kubectl -n "$ns" get pod -l app.kubernetes.io/name=orders -o jsonpath='{.items[0].metadata.name}')
spec=$(mktemp)
cat > "$spec" <<EOF
{"securityContext":{"runAsUser":1337,"runAsGroup":1337,"runAsNonRoot":true,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}
EOF
dbg=probe-$(date +%s)
kubectl -n "$ns" debug "$orders" -q --container="$dbg" --image="$CURL_IMAGE" --profile=restricted --custom="$spec" -- \
  curl -sS -m 5 -o /dev/null -w "plaintext GET http://$ip:8080/api/catalog/products from $orders → %{http_code}\n" "http://$ip:8080/api/catalog/products" >/dev/null
rm -f "$spec"
kubectl -n "$ns" wait pod "$orders" --for=jsonpath="{.status.ephemeralContainerStatuses[?(@.name=='$dbg')].state.terminated.reason}"=Completed --timeout=60s >/dev/null 2>&1 \
  || kubectl -n "$ns" wait pod "$orders" --for=jsonpath="{.status.ephemeralContainerStatuses[?(@.name=='$dbg')].state.terminated.reason}"=Error --timeout=30s >/dev/null 2>&1 || true
kubectl -n "$ns" logs "$orders" -c "$dbg" 2>&1 | sed 's/^/  /'
wait "$cap" || true

echo; echo "## capture: one line per TCP segment with payload, classified by its first bytes"
python3 - "$out" "$ip" <<'PY'
import re, sys
from collections import Counter
src, me = sys.argv[1], sys.argv[2]
pkts, cur = [], None
for line in open(src, errors="replace"):
    m = re.match(r"(\d\d:\d\d:\d\d\.\d+) IP (\S+) > (\S+): Flags \[([^\]]*)\].*length (\d+)", line)
    if m:
        cur = {"t": m[1], "src": m[2], "dst": m[3].rstrip(":"), "flags": m[4], "len": int(m[5]), "hex": ""}
        pkts.append(cur)
    elif cur and line.strip().startswith("0x"):
        cur["hex"] += "".join(line.split(":", 1)[1].split())
def payload(p):
    b = bytes.fromhex(p["hex"]); ihl = (b[0] & 0x0F) * 4; doff = (b[ihl + 12] >> 4) * 4
    return b[ihl + doff:]
def hello(d):
    """SNI + ALPN of a ClientHello: Istio names the upstream cluster in SNI and offers istio-* ALPN."""
    try:
        i = 9 + 2 + 32; i += 1 + d[i]; i += 2 + int.from_bytes(d[i:i+2], "big"); i += 1 + d[i]
        end = i + 2 + int.from_bytes(d[i:i+2], "big"); i += 2; sni = alpn = "?"
        while i + 4 <= min(end, len(d)):
            t, n = int.from_bytes(d[i:i+2], "big"), int.from_bytes(d[i+2:i+4], "big"); e = d[i+4:i+4+n]
            if t == 0: sni = e[5:].decode(errors="replace")
            if t == 16:
                j, names = 2, []
                while j < len(e): names.append(e[j+1:j+1+e[j]].decode(errors="replace")); j += 1 + e[j]
                alpn = ",".join(names)
            i += 4 + n
        return f", SNI {sni}, ALPN {alpn}"
    except Exception:
        return ""
kinds = Counter()
for p in pkts:
    if p["len"] == 0:
        if "R" in p["flags"]:
            by_catalog = p["src"].rsplit(".", 1)[0] == me
            what = "RST from the catalog sidecar: connection rejected" if by_catalog else "RST from the client (closes a pooled connection)"
            print(f'  {p["t"]}  {p["src"]:>20} > {p["dst"]:<20}       {what}'); kinds["RST by catalog" if by_catalog else "RST by client"] += 1
        continue
    d = payload(p)
    if d[:2] == b"\x16\x03": k = "TLS handshake" + (" (ClientHello" + hello(d) + ")" if len(d) > 5 and d[5] == 1 else "")
    elif d[:2] == b"\x14\x03": k = "TLS ChangeCipherSpec"
    elif d[:2] == b"\x17\x03": k = "TLS application data (encrypted)"
    elif d[:2] == b"\x15\x03": k = "TLS alert"
    elif re.match(rb"(GET|POST|PUT|DELETE|HEAD) /", d) or d.startswith(b"HTTP/1."): k = "PLAINTEXT HTTP: " + d.split(b"\r\n")[0].decode(errors="replace")
    else: k = f"other ({d[:8].hex()})"
    kinds[k.split(":")[0].split(" (")[0]] += 1
    print(f'  {p["t"]}  {p["src"]:>20} > {p["dst"]:<20} {p["len"]:>5} B  {k}')
print("\n  totals:", dict(kinds))
PY
