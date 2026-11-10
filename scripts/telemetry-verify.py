#!/usr/bin/env python3
"""Week 9: verify every arrow of the telemetry data-flow diagram against the running cluster.

Needs port-forwards (see scripts/observability-up.sh): Prometheus :9090, Jaeger :16686, Grafana :3000.
Grafana credentials are read from the git-ignored k8s/observability/grafana-admin.env and are only
sent to localhost:3000 (never printed).

Usage: scripts/telemetry-verify.py [--window-start ISO8601 --window-end ISO8601] [--export DIR]
  --export DIR   also writes the result of every dashboard panel query (run through Grafana's
                 /api/ds/query, i.e. exactly what the panels show) to DIR/grafana-panel-results.json
"""
import argparse, base64, datetime as dt, json, os, subprocess, sys, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROM, JAEGER, GRAFANA = "http://127.0.0.1:9090", "http://127.0.0.1:16686", "http://127.0.0.1:3000"
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  —  {detail}" if detail else ""), flush=True)


def get(url, auth=None, data=None):
    req = urllib.request.Request(url, data=json.dumps(data).encode() if data is not None else None)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if auth:
        req.add_header("Authorization", "Basic " + base64.b64encode(auth.encode()).decode())
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def promq(q):
    return get(PROM + "/api/v1/query?" + urllib.parse.urlencode({"query": q}))["data"]["result"]


def kubectl(*args):
    return subprocess.run(["kubectl", *args], capture_output=True, text=True).stdout


def grafana_auth():
    env = dict(line.strip().split("=", 1) for line in open(os.path.join(ROOT, "k8s/observability/grafana-admin.env")) if "=" in line)
    return f"{env['admin-user']}:{env['admin-password']}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--window-start"); ap.add_argument("--window-end"); ap.add_argument("--export")
    a = ap.parse_args()
    now = dt.datetime.now(dt.timezone.utc)
    w_end = dt.datetime.fromisoformat(a.window_end.replace("Z", "+00:00")) if a.window_end else now
    w_start = dt.datetime.fromisoformat(a.window_start.replace("Z", "+00:00")) if a.window_start else now - dt.timedelta(minutes=15)
    print(f"# telemetry-verify {now:%Y-%m-%dT%H:%M:%SZ}  (query window {w_start:%H:%M:%S}–{w_end:%H:%M:%S}Z)\n")

    print("## GitOps state")
    apps = json.loads(kubectl("-n", "argocd", "get", "applications", "-o", "json"))["items"]
    for app in apps:
        st = app["status"]
        check(f"Argo CD app {app['metadata']['name']} Synced/Healthy",
              st["sync"]["status"] == "Synced" and st["health"]["status"] == "Healthy",
              f"{st['sync']['status']}/{st['health']['status']} @ {st['sync'].get('revision', '')[:7]}")
    pods = json.loads(kubectl("-n", "observability", "get", "pods", "-o", "json"))["items"]
    for p in pods:
        ready = all(c["ready"] for c in p["status"].get("containerStatuses", []))
        check(f"observability pod {p['metadata']['labels']['app.kubernetes.io/name']} ready", ready,
              p["spec"]["containers"][0]["image"].split("@")[0])

    print("\n## ① App runtime → Collector (pull: /metrics, push: OTLP)")
    up = promq('up{job="kubernetes-pods"}')
    by_app = {}
    for r in up:
        by_app.setdefault((r["metric"]["namespace"], r["metric"]["app"]), []).append(r["value"][1])
    for ns in ("shop-dev", "shop-staging", "shop-prod"):
        for app_ in ("catalog", "orders"):
            v = by_app.get((ns, app_), [])
            check(f"scrape target {ns}/{app_} up", bool(v) and all(x == "1" for x in v), f"{len(v)} pod(s)")
    check("scrape target ingress-traefik/traefik up", all(x == "1" for x in by_app.get(("ingress-traefik", "traefik"), ["0"])))
    check("web (nginx, not instrumented) is NOT scraped", not any(k[1] == "web" for k in by_app))
    accepted = promq('sum(rate(otelcol_receiver_accepted_spans_total[5m]))')
    refused = promq('sum(rate(otelcol_receiver_refused_spans_total[5m]))')
    acc = float(accepted[0]["value"][1]) if accepted else 0.0
    ref = float(refused[0]["value"][1]) if refused else 0.0
    check("Collector receives OTLP spans, refuses none", acc > 0 and ref == 0, f"{acc:.1f} spans/s accepted, {ref:.1f} refused")

    print("\n## ② Collector → Prometheus (remote write) — RED metrics")
    for env in ("dev", "staging", "prod"):
        r = promq(f'sum by (service) (rate(http_server_request_duration_seconds_count{{environment="{env}",http_route=~"/api/.*"}}[5m]))')
        svcs = {x["metric"]["service"]: float(x["value"][1]) for x in r}
        check(f"RED series for {env}: catalog + orders", {"catalog", "orders"} <= set(svcs),
              ", ".join(f"{k} {v:.1f} req/s" for k, v in sorted(svcs.items())))
    routes = {x["metric"]["http_route"] for x in promq('count by (http_route) (http_server_request_duration_seconds_count)')}
    check("http_route is a bounded template (no raw ids)", not any(any(ch.isdigit() for ch in r) for r in routes), ", ".join(sorted(routes)))
    ex = get(PROM + "/api/v1/query_exemplars?" + urllib.parse.urlencode({
        "query": "http_server_request_duration_seconds_bucket", "start": int(w_start.timestamp()), "end": int(w_end.timestamp())}))["data"]
    n_ex = sum(len(s["exemplars"]) for s in ex)
    check("trace_id exemplars stored on duration buckets", n_ex > 0 and "trace_id" in ex[0]["exemplars"][0]["labels"], f"{n_ex} exemplars")
    check("Traefik edge metrics present", bool(promq('traefik_router_requests_total{router=~"shop-prod-.*"}')))
    check("client-side histogram orders → catalog present", bool(promq('http_client_request_duration_seconds_count{environment="prod"}')))
    rules = get(PROM + "/api/v1/rules")["data"]["groups"]
    names = {r["name"] for g in rules for r in g["rules"]}
    check("RED recording + alert rules loaded", {"shoplite:http_requests:rate1m", "ShopLiteHighErrorRate", "ShopLiteSlowRequests"} <= names, f"{len(names)} rules")

    print("\n## ③ Collector → Jaeger (OTLP) — distributed traces")
    services = set(get(JAEGER + "/api/services")["data"])
    check("Jaeger has traefik, orders, catalog", {"traefik", "orders", "catalog"} <= services, ", ".join(sorted(services)))
    q = urllib.parse.urlencode({"service": "orders", "operation": "POST /api/orders", "limit": 50,
                                "start": int(w_start.timestamp() * 1e6), "end": int(w_end.timestamp() * 1e6),
                                "tags": json.dumps({"http.response.status_code": "201"})})
    traces = get(JAEGER + "/api/traces?" + q)["data"]
    full = [t for t in traces if {t["processes"][s["processID"]]["serviceName"] for s in t["spans"]} >= {"traefik", "orders", "catalog"}]
    check("POST /api/orders traces span traefik → orders → catalog", len(full) > 0, f"{len(full)}/{len(traces)} traces cross 3 services")
    if full:
        t = full[0]
        ids = {s["spanID"] for s in t["spans"]}
        orphan = [s for s in t["spans"] if s.get("references") and s["references"][0]["spanID"] not in ids]
        check("traceparent propagation: one trace id, every parent span present", not orphan,
              f"trace {t['traceID'][:16]}…, {len(t['spans'])} spans, {len(orphan)} orphans")
        attrs = {x["key"] for p in t["processes"].values() for x in p["tags"]}
        check("spans enriched with k8s.* by the Collector", {"k8s.pod.name", "k8s.namespace.name", "k8s.deployment.name"} <= attrs)
        tags = {x["key"] for s in t["spans"] for x in s["tags"]}
        check("no SQL parameters recorded (enhancedDatabaseReporting off)", "db.statement.parameters" not in tags and "db.query.parameter" not in " ".join(tags))
    hits = 0
    for svc in ("catalog", "orders"):
        for path in ("/healthz", "/readyz", "/metrics"):
            q = urllib.parse.urlencode({"service": svc, "limit": 5, "tags": json.dumps({"url.path": path}),
                                        "start": int(w_start.timestamp() * 1e6), "end": int(w_end.timestamp() * 1e6)})
            hits += len(get(JAEGER + "/api/traces?" + q)["data"])
    check("probes and scrapes are not traced (/healthz, /readyz, /metrics)", hits == 0, f"{hits} traces found")

    print("\n## ④ Grafana → Prometheus / Jaeger (what the dashboard shows)")
    auth = grafana_auth()
    for uid in ("prometheus", "jaeger"):
        h = get(f"{GRAFANA}/api/datasources/uid/{uid}/health", auth)
        check(f"Grafana data source {uid} healthy", h.get("status") == "OK", h.get("message", ""))
    dash = get(f"{GRAFANA}/api/dashboards/uid/shoplite-red", auth)
    check("RED dashboard provisioned from git", bool(dash["meta"].get("provisioned")),
          f"{dash['dashboard']['title']} · {sum(p['type'] != 'row' for p in dash['dashboard']['panels'])} panels")
    export = []
    for env in ("prod",):
        for p in dash["dashboard"]["panels"]:
            if p["type"] == "row":
                continue
            frames_total, errors = 0, []
            for t in p["targets"]:
                body = {"queries": [], "from": str(int(w_start.timestamp() * 1000)), "to": str(int(w_end.timestamp() * 1000))}
                qd = json.loads(json.dumps(t).replace("$env", env).replace("$service", ".*").replace("shop-$env", f"shop-{env}"))
                qd.update({"intervalMs": 15000, "maxDataPoints": 300})
                if qd.get("datasource", {}).get("uid") == "prometheus":
                    qd["expr"] = qd["expr"].replace("$__rate_interval", "1m")
                body["queries"].append(qd)
                res = get(f"{GRAFANA}/api/ds/query", auth, body)["results"][t["refId"]]
                if res.get("error"):
                    errors.append(res["error"])
                frames = res.get("frames", [])
                frames_total += sum(1 for f in frames if f["data"]["values"] and f["data"]["values"][0])
                export.append({"panel": p["title"], "env": env, "refId": t["refId"], "query": qd.get("expr") or qd.get("tags"),
                               "frames": [{"name": f["schema"].get("name"), "fields": [fl["name"] for fl in f["schema"]["fields"]],
                                           "labels": [fl.get("labels") for fl in f["schema"]["fields"]], "values": f["data"]["values"]}
                                          for f in frames]})
            check(f"panel “{p['title']}” returns data ({env})", frames_total > 0 and not errors,
                  "; ".join(errors) if errors else f"{frames_total} series/frames")
    if a.export:
        os.makedirs(a.export, exist_ok=True)
        with open(os.path.join(a.export, "grafana-panel-results.json"), "w") as f:
            json.dump({"window": [w_start.isoformat(), w_end.isoformat()], "results": export}, f)

    print("\n## NetworkPolicy: only the Collector may scrape")
    out = subprocess.run(["kubectl", "-n", "shop-prod", "run", "scrape-probe", "--rm", "-i", "--restart=Never", "--quiet",
                          "--image=busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec",
                          "--overrides", json.dumps({"spec": {"securityContext": {"runAsNonRoot": True, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
                                                              "containers": [{"name": "scrape-probe", "image": "busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec",
                                                                              "command": ["sh", "-c", "sleep 3; wget -q -T 3 -O /dev/null http://orders.shop-prod.svc.cluster.local/metrics && echo REACHABLE || echo BLOCKED"],
                                                                              "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}}}]}})],
                         capture_output=True, text=True, timeout=120).stdout
    check("pod in shop-prod (not the Collector) cannot read orders /metrics", "BLOCKED" in out, out.strip().splitlines()[-1] if out.strip() else "no output")

    print(f"\n{sum(results)}/{len(results)} checks passed")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
