#!/usr/bin/env bash
# Week 7: capture cluster runtime state and verify it matches the designed topology.
# Output → docs/week7/evidence/*.txt
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=docs/week7/evidence
mkdir -p "$OUT"
NS=shop
INGRESS="http://127.0.0.1:8080"
H='Host: shop.local'

section() { printf '\n$ %s\n' "$*"; "$@" 2>&1; }
shell() { printf '\n$ %s\n' "$1"; bash -c "$1" 2>&1; }

# Run a throw-away busybox pod (restricted-PSA compliant), wait for it to finish, print its logs.
oneshot() { # namespace name script
  local ns=$1 name=$2 cmd
  cmd=$(printf '%s' "$3" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  kubectl -n "$ns" delete pod "$name" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl -n "$ns" run "$name" --restart=Never --image=busybox:1.37 --overrides="{\"spec\":{
    \"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":65534,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},
    \"containers\":[{\"name\":\"$name\",\"image\":\"busybox:1.37\",\"command\":[\"sh\",\"-c\",$cmd],
    \"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}}}]}}" >/dev/null
  kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name" --timeout=90s >/dev/null 2>&1 ||
    kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Failed "pod/$name" --timeout=5s >/dev/null 2>&1
  kubectl -n "$ns" logs "$name"
  kubectl -n "$ns" delete pod "$name" --wait=false >/dev/null 2>&1
}

# ── 00 · consolidated status snapshot (the "kubectl cluster status outputs" deliverable) ──
{
  echo "# kubectl cluster status — captured $(date -u '+%Y-%m-%d %H:%M UTC')"
  section kubectl get nodes -o wide
  section kubectl get all -n ingress-traefik -o wide
  section kubectl get all -n $NS -o wide
  section kubectl get ingressclass,ingress -A
  section kubectl get configmap,secret,pvc,networkpolicy -n $NS
  section kubectl get pv,storageclass
  section kubectl get endpointslices -n $NS
} > "$OUT/00-kubectl-status.txt"

# ── 01 · cluster ────────────────────────────────────────────────────────────
{
  echo "# Cluster — captured $(date -u '+%Y-%m-%d %H:%M UTC')"
  section kubectl version
  section kubectl cluster-info
  section kubectl get nodes -o wide --show-labels
  section kubectl get namespaces -L pod-security.kubernetes.io/enforce
} > "$OUT/01-cluster.txt"

# ── 02 · workloads ──────────────────────────────────────────────────────────
{
  section kubectl -n $NS get deployments,replicasets,statefulsets -o wide
  section kubectl -n $NS get pods -o wide -L app.kubernetes.io/name,tier
  section kubectl -n ingress-traefik get deploy,pods -o wide
  shell "kubectl -n $NS get pods -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,OWNER:.metadata.ownerReferences[0].kind/.metadata.ownerReferences[0].name,UID:.spec.securityContext.runAsUser,RO_ROOTFS:.spec.containers[0].securityContext.readOnlyRootFilesystem,IMAGE:.spec.containers[0].image'"
} > "$OUT/02-workloads.txt"

# ── 03 · services & endpoints ───────────────────────────────────────────────
{
  section kubectl -n $NS get services -o wide
  section kubectl -n $NS get endpointslices -o wide
  section kubectl -n ingress-traefik get service traefik -o wide
  echo; echo "# CoreDNS view from inside the namespace: ClusterIP Services resolve to a virtual IP,"
  echo "# the headless postgres Service resolves straight to the pod IP."
  echo '$ busybox: nslookup <svc>.shop.svc.cluster.local'
  oneshot $NS dns-probe 'for n in catalog orders web postgres postgres-0.postgres; do
    printf "%-40s -> " "$n.shop.svc.cluster.local"
    nslookup "$n.shop.svc.cluster.local" 2>/dev/null | awk "/^Address/ && !/#53|:53/ {print \$2}" | head -1
  done'
} > "$OUT/03-services-endpoints.txt"

# ── 04 · ingress ────────────────────────────────────────────────────────────
{
  section kubectl get ingressclass
  section kubectl -n $NS get ingress -o wide
  section kubectl -n $NS describe ingress shop
} > "$OUT/04-ingress.txt"

# ── 05 · configuration injection (ConfigMap vs Secret) ──────────────────────
{
  section kubectl -n $NS get configmaps,secrets
  section kubectl -n $NS describe "$(kubectl -n $NS get secret -o name | grep db-credentials)"
  echo; echo "# Env inside an orders pod (ConfigMap → envFrom, Secret → secretKeyRef). Values of *PASSWORD* masked."
  shell "kubectl -n $NS exec deploy/orders -- /nodejs/bin/node -e \"for (const k of Object.keys(process.env).filter(k => /^(PG|CATALOG_|POD_)/.test(k)).sort()) console.log(k + '=' + (/PASSWORD/.test(k) ? '******** (' + process.env[k].length + ' chars, from Secret)' : process.env[k]))\""
  echo; echo "# ConfigMap mounted as a file in the web pod"
  shell "kubectl -n $NS exec deploy/web -- ls -l /usr/share/nginx/html/config/"
  shell "kubectl -n $NS exec deploy/web -- cat /usr/share/nginx/html/config/config.json"
  echo; echo "# Secret mounted as files in postgres (0440, group 70) — listed, not printed"
  shell "kubectl -n $NS exec postgres-0 -- ls -lL /run/secrets/db/"
  shell "kubectl -n $NS exec postgres-0 -- sh -c 'env | grep -c PASSWORD= || true'"
} > "$OUT/05-config-injection.txt"

# ── 06 · state ──────────────────────────────────────────────────────────────
{
  section kubectl get storageclass
  section kubectl -n $NS get pvc -o wide
  section kubectl get pv
  echo; echo "# Database-per-service inside the StatefulSet"
  shell "kubectl -n $NS exec postgres-0 -- psql -U postgres -c '\\l catalog' -c '\\l orders' -c '\\du'"
  shell "kubectl -n $NS exec postgres-0 -- psql -U postgres -d catalog -c 'SELECT id, sku, name, price_cents, stock FROM products ORDER BY id'"
} > "$OUT/06-storage-state.txt"

# ── 07 · traffic through the Ingress ────────────────────────────────────────
{
  echo "# Requests enter at 127.0.0.1:8080 (kind port-map) → node :30080 (NodePort) → Traefik → Service → Pod"
  shell "curl -s -o /dev/null -w 'GET /                      → %{http_code}  %{content_type}\n' -H '$H' $INGRESS/"
  shell "curl -s -H '$H' $INGRESS/config/config.json"
  shell "curl -s -H '$H' $INGRESS/api/catalog/products/1"
  echo; echo "# Load balancing: 8 requests to /api/catalog/products, pod that answered (X-Served-By)"
  shell "for i in \$(seq 8); do curl -s -D - -o /dev/null -H '$H' $INGRESS/api/catalog/products | grep -i x-served-by; done | sort | uniq -c"
  echo; echo "# East-west: POST /api/orders → orders pod → catalog Service (ClusterIP) → catalog pod → postgres"
  shell "for p in 1 2 3 4; do curl -s -H '$H' -H 'Content-Type: application/json' -d \"{\\\"productId\\\":\$p,\\\"quantity\\\":1}\" $INGRESS/api/orders; echo; done"
  shell "curl -s -H '$H' $INGRESS/api/orders | head -c 400; echo"
  echo; echo "# Negative routing cases"
  shell "curl -s -o /dev/null -w 'unknown Host header  → %{http_code}\n' -H 'Host: other.local' $INGRESS/api/catalog/products"
  shell "curl -s -o /dev/null -w 'unknown API path     → %{http_code}\n' -H '$H' $INGRESS/api/catalog/nope"
  shell "curl -s -o /dev/null -w 'invalid order        → %{http_code}\n' -H '$H' -H 'Content-Type: application/json' -d '{\"productId\":1,\"quantity\":0}' $INGRESS/api/orders"
  echo; echo "# Traefik access log: router chosen by Host/Path match and the pod endpoint it proxied to"
  shell "kubectl -n ingress-traefik logs deploy/traefik --tail=12 | grep -E 'shop|\" 404 '"
} > "$OUT/07-traffic-tests.txt"

# ── 08 · network policies ───────────────────────────────────────────────────
probe() { # $1=description $2=command ; expectation printed by caller
  printf '%-58s' "$1"
  if bash -c "$2" >/dev/null 2>&1; then echo "CONNECTED"; else echo "BLOCKED (timeout)"; fi
}
{
  section kubectl -n $NS get networkpolicies
  echo; echo "# Reachability matrix (expected: only Traefik→apps, orders→catalog, apps→postgres)"
  probe "orders  → catalog:80       (allowed)" \
    "kubectl -n $NS exec deploy/orders -- /nodejs/bin/node -e \"fetch('http://catalog/healthz',{signal:AbortSignal.timeout(3000)}).then(r=>process.exit(r.ok?0:1),()=>process.exit(1))\""
  probe "catalog → postgres:5432    (allowed)" \
    "kubectl -n $NS exec deploy/catalog -- /nodejs/bin/node -e \"require('net').connect(5432,'postgres').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1)).setTimeout(3000,()=>process.exit(1))\""
  probe "web     → catalog:80       (denied)" \
    "kubectl -n $NS exec deploy/web -- wget -T 3 -qO- http://catalog/healthz"
  probe "web     → postgres:5432    (denied)" \
    "kubectl -n $NS exec deploy/web -- nc -z -w 3 postgres 5432"
  probe "catalog → orders:80        (denied)" \
    "kubectl -n $NS exec deploy/catalog -- /nodejs/bin/node -e \"fetch('http://orders/healthz',{signal:AbortSignal.timeout(3000)}).then(r=>process.exit(r.ok?0:1),()=>process.exit(1))\""
  probe "web     → web (self, control: wget/nc present)" \
    "kubectl -n $NS exec deploy/web -- sh -c 'wget -T 3 -qO- http://127.0.0.1:8080/healthz && nc -z -w 3 127.0.0.1 8080'"
  oneshot default np-probe '
    if wget -T 5 -qO- --header "Host: shop.local" http://traefik.ingress-traefik.svc.cluster.local/healthz >/dev/null 2>&1
    then r=CONNECTED; else r=FAILED; fi
    printf "%-58s%s\n" "default-ns pod → Traefik → web     (control, allowed)" "$r"
    if wget -T 3 -qO- http://catalog.shop.svc.cluster.local/healthz >/dev/null 2>&1
    then r=CONNECTED; else r="BLOCKED (timeout)"; fi
    printf "%-58s%s\n" "default-ns pod → catalog.shop:80   (denied)" "$r"'
} > "$OUT/08-network-policies.txt"

# ── 09 · designed vs actual topology ────────────────────────────────────────
PASS=0; FAIL=0
check() { # name expected actual
  local r="✓"; [ "$2" = "$3" ] && PASS=$((PASS + 1)) || { r="✗"; FAIL=$((FAIL + 1)); }
  printf '%-46s %-28s %-28s %s\n' "$1" "$2" "$3" "$r"
}
j() { kubectl "$@" 2>/dev/null; }
{
  echo "# Designed topology (docs/week7/diagrams) vs. runtime state — $(date -u '+%Y-%m-%d %H:%M UTC')"
  printf '%-46s %-28s %-28s %s\n' CHECK EXPECTED ACTUAL OK
  check "nodes Ready"                        "3" "$(j get nodes --no-headers | grep -c ' Ready')"
  for d in catalog orders web; do
    check "deploy/$d ready replicas"         "2/2" "$(j -n $NS get deploy $d -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
    check "deploy/$d pods on distinct nodes"  "2" "$(j -n $NS get pods -l app.kubernetes.io/name=$d -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l | tr -d ' ')"
    check "svc/$d type:port→targetPort"      "ClusterIP:80→http" "$(j -n $NS get svc $d -o jsonpath='{.spec.type}:{.spec.ports[0].port}→{.spec.ports[0].targetPort}')"
    check "svc/$d ready endpoints"           "2" "$(j -n $NS get endpointslices -l kubernetes.io/service-name=$d -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{"\n"}{end}' | grep -c .)"
  done
  check "statefulset/postgres ready"         "1/1" "$(j -n $NS get sts postgres -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
  check "svc/postgres headless"              "None" "$(j -n $NS get svc postgres -o jsonpath='{.spec.clusterIP}')"
  check "pvc/data-postgres-0"                "Bound:1Gi" "$(j -n $NS get pvc data-postgres-0 -o jsonpath='{.status.phase}:{.status.capacity.storage}')"
  check "deploy/traefik ready"               "2/2" "$(j -n ingress-traefik get deploy traefik -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
  check "deploy/traefik pods on distinct nodes" "2" "$(j -n ingress-traefik get pods -l app.kubernetes.io/name=traefik -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l | tr -d ' ')"
  check "svc/traefik NodePort"               "NodePort:30080" "$(j -n ingress-traefik get svc traefik -o jsonpath='{.spec.type}:{.spec.ports[0].nodePort}')"
  check "ingress/shop class"                 "traefik" "$(j -n $NS get ingress shop -o jsonpath='{.spec.ingressClassName}')"
  check "ingress/shop host"                  "shop.local" "$(j -n $NS get ingress shop -o jsonpath='{.spec.rules[0].host}')"
  check "ingress/shop paths"                 "/api/catalog,/api/orders,/" "$(j -n $NS get ingress shop -o jsonpath='{range .spec.rules[0].http.paths[*]}{.path},{end}' | sed 's/,$//')"
  check "ingress/shop status address"        "127.0.0.1" "$(j -n $NS get ingress shop -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  check "configmaps (app)"                   "4" "$(j -n $NS get cm --no-headers | grep -vc kube-root-ca)"
  check "secret db-credentials-<hash> keys"  "3" "$(j -n $NS get secret -o jsonpath='{range .items[*]}{.metadata.name} {end}' | tr ' ' '\n' | grep db-credentials | head -1 | xargs -I{} kubectl -n $NS get secret {} -o go-template='{{len .data}}')"
  check "networkpolicies"                    "4" "$(j -n $NS get netpol --no-headers | wc -l | tr -d ' ')"
  check "namespace shop PSA enforce"         "restricted" "$(j get ns $NS -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
  check "HTTP GET / via ingress"             "200" "$(curl -s -o /dev/null -w '%{http_code}' -H "$H" $INGRESS/)"
  check "HTTP GET /api/catalog/products"     "200" "$(curl -s -o /dev/null -w '%{http_code}' -H "$H" $INGRESS/api/catalog/products)"
  check "HTTP GET /api/orders"               "200" "$(curl -s -o /dev/null -w '%{http_code}' -H "$H" $INGRESS/api/orders)"
  echo; echo "RESULT: $PASS passed, $FAIL failed"
} > "$OUT/09-topology-verification.txt"

cat "$OUT/09-topology-verification.txt"
echo; cat "$OUT/08-network-policies.txt" | tail -8
[ "$FAIL" -eq 0 ]
