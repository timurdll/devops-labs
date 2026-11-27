#!/usr/bin/env python3
"""Week 12: release a new catalog version through Argo Rollouts under load and record what happens.

  1. baseline: steady open-model load on the environment's edge (default 10 req/s):
       half GET /api/catalog/products   (gateway → catalog: users see a canary 5xx directly)
       half POST /api/orders            (gateway → orders → catalog: the Week 11 breaker may hide it)
  2. release = a git commit: services.catalog.image.tag in environments/<env>/values.yaml is set to
     --tag, committed and pushed; Argo CD is asked to refresh (the same path as any release).
  3. watch until the Rollout is Healthy on the new version (promoted) or aborted (rolled back),
     then --tail seconds more.

Recorded every second: requests by status and by the version of the catalog pod that answered
(X-Served-By / catalogServedBy → pod label `version`), and every 2 s the Rollout's phase, step,
canary weight (VirtualService) and the AnalysisRun's measurements.
Output → <out>/timeline.csv, timeline.png, rollout-events.txt, analysisrun.yaml, summary.txt.

Usage: rollout-experiment.py --tag 1.3.0 --expect abort   --out docs/week12/evidence/r1-…
       rollout-experiment.py --tag 1.3.1 --expect promote --out docs/week12/evidence/r2-…
"""
import argparse
import concurrent.futures as cf
import csv
import json
import os
import random
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request

EDGE = "http://127.0.0.1:8080"


def sh(*args, check=True):
    return subprocess.run(list(args), capture_output=True, text=True, check=check).stdout


def kjson(*args):
    out = subprocess.run(["kubectl", *args, "-o", "json"], capture_output=True, text=True)
    return json.loads(out.stdout) if out.returncode == 0 and out.stdout else {}


def request(host, kind, pid):
    if kind == "list":
        req = urllib.request.Request(f"{EDGE}/api/catalog/products", headers={"Host": host})
    else:
        body = json.dumps({"productId": pid, "quantity": 1}).encode()
        req = urllib.request.Request(f"{EDGE}/api/orders", data=body, method="POST",
                                     headers={"Host": host, "Content-Type": "application/json"})
    started = time.monotonic()
    served, degraded = "", ""
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            status, raw = res.status, res.read()
            degraded = res.headers.get("X-Degraded") or ""
            if kind == "list":
                served = res.headers.get("X-Served-By") or ""
            else:
                served = json.loads(raw).get("catalogServedBy", "")
    except urllib.error.HTTPError as err:
        status = err.code
        served = err.headers.get("X-Served-By") or "" if kind == "list" else ""
    except Exception:  # noqa: BLE001 — refused / timeout: counted, never fatal
        status = 0
    return status, served, degraded, time.monotonic() - started


def release(env, tag):
    path = f"environments/{env}/values.yaml"
    text = open(path).read()
    new, n = re.subn(r'(\n  catalog:\n    image:\n      tag: )"[^"]*"', rf'\1"{tag}"', text)
    if n != 1:
        raise SystemExit(f"{path}: services.catalog.image.tag not found")
    open(path, "w").write(new)
    who = ["-c", f"user.name={sh('git', 'log', '-1', '--format=%an').strip()}",
           "-c", f"user.email={sh('git', 'log', '-1', '--format=%ae').strip()}"]
    sh("git", *who, "commit", "-q", "-m", f"release: catalog {tag} to {env} (Argo Rollouts canary)", path)
    sh("git", "push", "-q")
    sh("kubectl", "-n", "argocd", "annotate", "application", f"shoplite-{env}",
       "argocd.argoproj.io/refresh=hard", "--overwrite")
    return sh("git", "rev-parse", "--short", "HEAD").strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--expect", choices=["abort", "promote"], required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--env", default="staging")
    ap.add_argument("--rps", type=float, default=10)
    ap.add_argument("--baseline", type=int, default=30)
    ap.add_argument("--max", type=int, default=900, help="give up after this many seconds")
    ap.add_argument("--tail", type=int, default=60)
    a = ap.parse_args()
    ns, host = f"shop-{a.env}", f"{a.env}.shop.local"
    os.makedirs(a.out, exist_ok=True)

    results, states, pod_version = [], [], {}
    lock, stop = threading.Lock(), threading.Event()
    marks = {}
    t0 = time.time()

    def watcher():
        while not stop.is_set():
            t = time.time() - t0
            ro = kjson("-n", ns, "get", "rollout", "catalog")
            st = ro.get("status", {})
            vs = kjson("-n", ns, "get", "virtualservice", "catalog")
            weight = next((r.get("weight", 0) for h in vs.get("spec", {}).get("http", [])
                           for r in h.get("route", []) if r["destination"].get("subset") == "canary"), 0)
            runs = kjson("-n", ns, "get", "analysisrun", "-l", "app.kubernetes.io/name=catalog")
            ar = max(runs.get("items", []), key=lambda r: r["metadata"]["creationTimestamp"], default={})
            ar_status = ar.get("status", {}).get("phase", "") if ar and ar["metadata"]["creationTimestamp"] >= marks.get("release_iso", "~") else ""
            pods = kjson("-n", ns, "get", "pods", "-l", "app.kubernetes.io/name=catalog")
            with lock:
                for p in pods.get("items", []):
                    pod_version[p["metadata"]["name"]] = p["metadata"]["labels"].get("version", "?")
                states.append(dict(t=round(t, 1), phase=st.get("phase", ""), step=st.get("currentStepIndex", ""),
                                   weight=weight, abort=bool(st.get("abort")), analysis=ar_status,
                                   stable=st.get("stableRS", ""),
                                   message=st.get("message", "")[:120]))
            stop.wait(2)

    def fire(sec, kind, pid):
        status, served, degraded, lat = request(host, kind, pid)
        with lock:
            results.append((sec, kind, status, served, degraded, lat))

    def done():
        s = states[-1] if states else {}
        if "release" not in marks or time.time() - marks["release"] < 20:
            return False
        if a.expect == "abort" and s.get("abort"):
            return True
        return s.get("phase") == "Healthy" and s.get("stable") not in ("", stable_before)

    stable_before = kjson("-n", ns, "get", "rollout", "catalog").get("status", {}).get("stableRS")
    threading.Thread(target=watcher, daemon=True).start()
    print(f"{a.env}: {a.rps:g} req/s, release catalog {a.tag} after {a.baseline}s, expect {a.expect}", flush=True)
    rng = random.Random(12)
    end_at = None
    with cf.ThreadPoolExecutor(max_workers=64) as pool:
        i = 0
        while True:
            due = t0 + i / a.rps
            time.sleep(max(0, due - time.time()))
            sec = int(due - t0)
            if "release" not in marks and sec >= a.baseline:
                marks["release_iso"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                marks["release"] = time.time()
                commit = release(a.env, a.tag)
                marks["commit"] = commit
                print(f"  t={sec:>4}s  released {a.tag} as commit {commit}", flush=True)
            if end_at is None and (done() or sec > a.max):
                end_at = time.time() + a.tail
                marks["outcome_t"] = sec
                print(f"  t={sec:>4}s  rollout settled: {states[-1]}", flush=True)
            if end_at and time.time() > end_at:
                break
            kind = "list" if i % 2 == 0 else "order"
            pool.submit(fire, sec, kind, rng.choice([1, 2, 3]))
            i += 1
    stop.set()
    total = int(time.time() - t0)
    rel = int(marks["release"] - t0)

    # ── per-second timeline
    versions = sorted({v for v in pod_version.values()})
    rows = []
    for sec in range(total):
        rs = [r for r in results if r[0] == sec]
        st = [s for s in states if int(s["t"]) <= sec]
        s = st[-1] if st else {}
        row = dict(t=sec, sent=len(rs), s2xx=sum(200 <= r[2] < 300 for r in rs),
                   s5xx=sum(r[2] >= 500 for r in rs), errors=sum(r[2] == 0 for r in rs),
                   degraded=sum(bool(r[4]) for r in rs),
                   list5xx=sum(r[2] >= 500 and r[1] == "list" for r in rs),
                   weight=s.get("weight", 0), step=s.get("step", ""), phase=s.get("phase", ""),
                   analysis=s.get("analysis", ""))
        for v in versions:
            row[f"by_{v}"] = sum(pod_version.get(r[3]) == v for r in rs)
        rows.append(row)
    with open(f"{a.out}/timeline.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    # ── rollout state changes + AnalysisRun
    with open(f"{a.out}/rollout-events.txt", "w") as f:
        f.write(f"# Rollout shop-{a.env}/catalog, t = seconds since load start; release commit "
                f"{marks['commit']} at t={rel}\n")
        last = None
        for s in states:
            key = (s["phase"], s["step"], s["weight"], s["abort"], s["analysis"])
            if key != last:
                f.write(f"  t={s['t']:6.1f}s  phase={s['phase']:<12} step={s['step']!s:<3} canary weight={s['weight']:>3}%"
                        f"  abort={s['abort']!s:<5} analysis={s['analysis']:<12} {s['message']}\n")
                last = key
        f.write("\n# kubectl get events (Rollout + AnalysisRun)\n")
        f.write(sh("kubectl", "-n", ns, "get", "events", "--sort-by=.lastTimestamp",
                   "--field-selector", "involvedObject.name=catalog", check=False)[-6000:])
    runs = kjson("-n", ns, "get", "analysisrun", "-l", "app.kubernetes.io/name=catalog")
    ar = max(runs.get("items", []), key=lambda r: r["metadata"]["creationTimestamp"], default=None)
    if ar:
        sh_out = subprocess.run(["kubectl", "-n", ns, "get", "analysisrun", ar["metadata"]["name"], "-o", "yaml"],
                                capture_output=True, text=True).stdout
        sh_out = re.sub(r"(?m)^  (managedFields|uid|resourceVersion|generation):.*(\n    .*)*\n", "", sh_out)
        open(f"{a.out}/analysisrun.yaml", "w").write(sh_out)

    # ── checks
    ro = kjson("-n", ns, "get", "rollout", "catalog").get("status", {})
    after = [r for r in results if r[0] >= rel]
    canary_v = a.tag
    first_canary_5xx = min((r[0] for r in after if r[2] >= 500 and pod_version.get(r[3]) == canary_v), default=None)
    abort_t = next((s["t"] for s in states if s["abort"]), None)
    max_w = max((s["weight"] for s in states), default=0)
    tail = [r for r in results if marks.get("outcome_t") is not None and r[0] > marks["outcome_t"] + 5]
    lines = [f"release catalog {a.tag} to {a.env} (commit {marks['commit']}) at t={rel}s, expect: {a.expect}",
             f"requests: {len(results)} ({sum(r[1] == 'list' for r in results)} GET products, "
             f"{sum(r[1] == 'order' for r in results)} POST orders)",
             f"5xx: {sum(r[2] >= 500 for r in results)} total, {sum(r[2] >= 500 and r[1] == 'list' for r in results)} on GET products, "
             f"{sum(r[2] >= 500 and r[1] == 'order' for r in results)} on POST orders; transport errors {sum(r[2] == 0 for r in results)}; "
             f"degraded orders (breaker fallback) {sum(bool(r[4]) for r in results)}",
             f"answered by version: " + ", ".join(f"{v}={sum(pod_version.get(r[3]) == v for r in results)}" for v in versions),
             f"max canary weight seen: {max_w}%   final phase: {ro.get('phase')}   stableRS: {stable_before} → {ro.get('stableRS')}",
             ""]
    checks = []
    if a.expect == "abort":
        checks.append(("rollout aborted automatically", abort_t is not None, f"abort at t={abort_t}s"))
        checks.append(("canary never got more than the first step (10 %)", max_w <= 10, f"max {max_w}%"))
        checks.append(("stable version unchanged", ro.get("stableRS") == stable_before, ro.get("stableRS")))
        if first_canary_5xx is not None and abort_t is not None:
            checks.append(("abort within 3 min of the first canary 5xx", abort_t - first_canary_5xx <= 180,
                           f"first canary 5xx t={first_canary_5xx}s → abort t={abort_t}s = {abort_t - first_canary_5xx:.0f}s"))
        checks.append(("no 5xx after the rollback settled", not any(r[2] >= 500 for r in tail),
                       f"{sum(r[2] >= 500 for r in tail)} in {len(tail)} requests"))
    else:
        checks.append(("rollout promoted to 100 %", ro.get("phase") == "Healthy" and ro.get("stableRS") != stable_before,
                       f"stableRS {stable_before} → {ro.get('stableRS')}"))
        checks.append(("weights went through every step", {10, 25, 50} <= {s["weight"] for s in states},
                       sorted({s["weight"] for s in states})))
        checks.append(("AnalysisRun successful", (ar or {}).get("status", {}).get("phase") == "Successful",
                       (ar or {}).get("status", {}).get("phase")))
        checks.append(("0 user-visible 5xx", not any(r[2] >= 500 for r in results),
                       sum(r[2] >= 500 for r in results)))
    for name, ok, detail in checks:
        lines.append(f"{'PASS' if ok else 'FAIL'}  {name}  ({detail})")
    open(f"{a.out}/summary.txt", "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))

    # ── chart
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(11, 6), sharex=True, gridspec_kw={"height_ratios": [1, 1.4]})
        ts = [s["t"] for s in states]
        ax1.step(ts, [s["weight"] for s in states], where="post", color="#7a5af5", lw=2, label="canary weight (VirtualService)")
        ax1.set_ylabel("canary %")
        ax1.set_ylim(-5, 105)
        ax1.axvline(rel, color="grey", ls="--", lw=1)
        ax1.text(rel, 95, f" commit {marks['commit']}\n catalog {a.tag}", fontsize=8, va="top")
        if abort_t is not None:
            ax1.axvline(abort_t, color="#d1495b", ls="--", lw=1)
            ax1.text(abort_t, 60, " AnalysisRun failed\n → abort", color="#d1495b", fontsize=8)
        ax1.legend(loc="upper left", fontsize=8)
        x = [r["t"] for r in rows]
        bottom = [0] * len(rows)
        palette = ["#2e86ab", "#f18f01", "#3bb273", "#999999"]
        for k, v in enumerate(versions):
            ys = [r[f"by_{v}"] for r in rows]
            ax2.bar(x, ys, bottom=bottom, width=1.0, color=palette[k % len(palette)], label=f"answered by {v}")
            bottom = [b + y for b, y in zip(bottom, ys)]
        ax2.plot(x, [r["s5xx"] for r in rows], color="#d1495b", lw=1.5, label="5xx / s (user-visible)")
        ax2.plot(x, [r["degraded"] for r in rows], color="black", lw=1, ls=":", label="degraded orders / s")
        ax2.set_ylabel("requests / s")
        ax2.set_xlabel("seconds since load start")
        ax2.legend(loc="upper left", fontsize=8, ncol=3)
        fig.suptitle(f"Argo Rollouts canary of catalog {a.tag} in {a.env} ({a.expect})", fontsize=11)
        fig.tight_layout()
        fig.savefig(f"{a.out}/timeline.png", dpi=110)
    except ImportError:
        pass


if __name__ == "__main__":
    main()
