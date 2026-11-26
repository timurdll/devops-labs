#!/usr/bin/env python3
"""Week 11: run one chaos experiment under steady load and check its hypothesis.

Timeline:  baseline (steady state) → kubectl apply <experiment> → chaos → kubectl delete → recovery

Load is an open model: POST /api/orders is *scheduled* at a fixed rate (default 10/s) through
the staging edge (Traefik → gateway → orders → catalog), so slow answers do not slow the load down
(a closed loop would hide latency). Every second of the run is recorded:

  t, phase, sent, 2xx, 4xx, 5xx, 429, errors, degraded (X-Degraded header), p50, p95, max

Afterwards the orders logs give the breaker transitions (with timestamps) and Prometheus the
fallback/transition counters. Output → <out>/timeline.csv, timeline.png, transitions.txt,
summary.txt (hypothesis checks: PASS/FAIL).

Usage: chaos-experiment.py k8s/chaos/experiments/e1-catalog-latency.yaml --out docs/week11/evidence/e1
"""
import argparse
import concurrent.futures as cf
import csv
import datetime as dt
import json
import os
import random
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

EDGE = "http://127.0.0.1:8080"
PROM = "http://127.0.0.1:9090"

# Hypotheses, checked on the recorded timeline (docs/week11/README.md §6).
HYPOTHESES = {
    "e1": dict(max_5xx_ratio=0.0, chaos_p95_s=1.5, open_within_s=10, close_within_s=30, min_degraded=0.5),
    "e2": dict(max_5xx_ratio_known=0.0, chaos_p95_s=1.5, open_within_s=10, close_within_s=30),
    "e3": dict(max_5xx_ratio=0.0, breaker_stays_closed=True),
}


def kubectl(*args, check=True):
    return subprocess.run(["kubectl", *args], capture_output=True, text=True, check=check).stdout


def post_order(host, product_id):
    body = json.dumps({"productId": product_id, "quantity": 1}).encode()
    req = urllib.request.Request(
        f"{EDGE}/api/orders", data=body, method="POST",
        headers={"Host": host, "Content-Type": "application/json"},
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            status, degraded = res.status, res.headers.get("X-Degraded")
    except urllib.error.HTTPError as err:
        status, degraded = err.code, err.headers.get("X-Degraded")
    except Exception:  # noqa: BLE001 — connection refused / timeout: counted, never fatal
        status, degraded = 0, None
    return status, degraded, time.monotonic() - started


def pct(values, q):
    if not values:
        return 0.0
    s = sorted(values)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("experiment")
    ap.add_argument("--out", required=True)
    ap.add_argument("--env", default="staging")
    ap.add_argument("--rps", type=float, default=10)
    ap.add_argument("--baseline", type=int, default=60)
    ap.add_argument("--chaos", type=int, default=120, help="seconds before the experiment is deleted")
    ap.add_argument("--recovery", type=int, default=60)
    ap.add_argument("--ids", default="1,2,3", help="product ids ordered in every phase")
    ap.add_argument("--chaos-ids", default="", help="extra ids ordered only during chaos (cold cache)")
    a = ap.parse_args()

    name = os.path.basename(a.experiment).split("-")[0]
    ns = f"shop-{a.env}"
    host = f"{a.env}.shop.local"
    ids = [int(x) for x in a.ids.split(",")]
    chaos_ids = ids + [int(x) for x in a.chaos_ids.split(",") if x]
    os.makedirs(a.out, exist_ok=True)
    total = a.baseline + a.chaos + a.recovery
    results = []  # (second, product_id, status, degraded, latency)
    lock = threading.Lock()
    phase_marks = {}

    def phase_of(sec):
        return "baseline" if sec < a.baseline else "chaos" if sec < a.baseline + a.chaos else "recovery"

    def fire(sec, pid):
        status, degraded, latency = post_order(host, pid)
        with lock:
            results.append((sec, pid, status, degraded, latency))

    def controller(t0):
        time.sleep(max(0, t0 + a.baseline - time.time()))
        phase_marks["inject"] = time.time()
        out = subprocess.run(["kubectl", "apply", "-f", a.experiment], capture_output=True, text=True)
        print(f"  t={a.baseline:>4}s  inject: {out.stdout.strip() or out.stderr.strip()}", flush=True)
        time.sleep(max(0, t0 + a.baseline + a.chaos - time.time()))
        phase_marks["remove"] = time.time()
        out = subprocess.run(["kubectl", "delete", "-f", a.experiment, "--wait=true"], capture_output=True, text=True)
        print(f"  t={a.baseline + a.chaos:>4}s  remove: {out.stdout.strip() or out.stderr.strip()}", flush=True)

    print(f"{name}: {a.rps:g} orders/s for {total}s against {host} "
          f"(baseline {a.baseline}s, chaos {a.chaos}s, recovery {a.recovery}s)", flush=True)
    t0 = time.time()
    phase_marks["start"] = t0
    ctl = threading.Thread(target=controller, args=(t0,), daemon=True)
    ctl.start()
    rng = random.Random(11)
    with cf.ThreadPoolExecutor(max_workers=64) as pool:
        n = int(total * a.rps)
        for i in range(n):
            due = t0 + i / a.rps
            time.sleep(max(0, due - time.time()))
            sec = int(due - t0)
            pid = rng.choice(chaos_ids if phase_of(sec) == "chaos" else ids)
            pool.submit(fire, sec, pid)
    ctl.join()
    t_end = time.time()

    # ── per-second timeline
    rows = []
    for sec in range(total):
        rs = [r for r in results if r[0] == sec]
        lat = [r[4] for r in rs]
        rows.append(dict(
            t=sec, phase=phase_of(sec), sent=len(rs),
            s2xx=sum(200 <= r[2] < 300 for r in rs), s4xx=sum(400 <= r[2] < 500 and r[2] != 429 for r in rs),
            s5xx=sum(r[2] >= 500 for r in rs), s429=sum(r[2] == 429 for r in rs), errors=sum(r[2] == 0 for r in rs),
            degraded=sum(bool(r[3]) for r in rs),
            p50=round(pct(lat, 0.5), 3), p95=round(pct(lat, 0.95), 3), max=round(max(lat, default=0), 3),
        ))
    with open(f"{a.out}/timeline.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    # ── breaker transitions from the orders logs (timestamps from the container runtime)
    since = int(t_end - t0) + 30
    transitions = []
    for pod in kubectl("-n", ns, "get", "pods", "-l", "app.kubernetes.io/name=orders", "-o",
                       "jsonpath={.items[*].metadata.name}").split():
        for line in kubectl("-n", ns, "logs", pod, "-c", "orders", "--timestamps", f"--since={since}s",
                            check=False).splitlines():
            m = re.match(r"(\S+) orders: circuit (\S+) (\S+) → (\S+) \((.*)\)", line)
            if m:
                stamp, _, frac = m.group(1).rstrip("Z").partition(".")
                ts = dt.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%S").replace(
                    tzinfo=dt.timezone.utc).timestamp() + float("0." + (frac or "0"))
                transitions.append((ts - t0, pod, m.group(3), m.group(4), m.group(5)))
    transitions.sort()
    with open(f"{a.out}/transitions.txt", "w") as f:
        f.write(f"# circuit breaker transitions of orders in {ns} (t = seconds since load start; "
                f"fault injected at t={a.baseline}, removed at t={a.baseline + a.chaos})\n")
        for t, pod, fr, to, why in transitions:
            f.write(f"  t={t:7.1f}s  {pod:28} {fr:>9} → {to:<9} {why}\n")

    # ── Prometheus counters over the run
    def prom(q):
        url = f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": q, "time": t_end + 20})
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                return json.load(r)["data"]["result"]
        except Exception:  # noqa: BLE001
            return []
    window = f"{int(t_end - t0) + 20}s"
    prom_lines = []
    for q in [
        f'sum by (reason, result) (increase(dependency_fallback_total{{namespace="{ns}"}}[{window}]))',
        f'sum by (from, to) (increase(circuit_breaker_transitions_total{{namespace="{ns}"}}[{window}]))',
        f'sum by (outcome) (increase(circuit_breaker_calls_total{{namespace="{ns}"}}[{window}]))',
        f'sum (increase(dependency_retries_total{{namespace="{ns}"}}[{window}]))',
    ]:
        prom_lines.append(f"  {q}")
        for r in prom(q):
            prom_lines.append(f"      {json.dumps(r['metric'], sort_keys=True):60} {float(r['value'][1]):8.0f}")

    # ── hypothesis checks
    def ratio(phase, pred, rows_filter=None):
        sel = [r for r in results if phase_of(r[0]) == phase and (rows_filter is None or rows_filter(r))]
        return (sum(pred(r) for r in sel) / len(sel)) if sel else 0.0, len(sel)

    h = HYPOTHESES.get(name, {})
    checks = []
    inj, rem = a.baseline, a.baseline + a.chaos
    chaos_lat = [r[4] for r in results if inj + 10 <= r[0] < rem]
    if "max_5xx_ratio" in h:
        for ph in ("baseline", "chaos", "recovery"):
            v, n = ratio(ph, lambda r: r[2] >= 500 or r[2] == 0)
            checks.append((f"{ph}: 5xx/errors {v:.2%} of {n} orders ≤ {h['max_5xx_ratio']:.0%}", v <= h["max_5xx_ratio"]))
    if "max_5xx_ratio_known" in h:
        v, n = ratio("chaos", lambda r: r[2] >= 500 or r[2] == 0, lambda r: r[1] in ids)
        checks.append((f"chaos: 5xx/errors for cached products {v:.2%} of {n} = 0", v == 0))
        cold = [r for r in results if phase_of(r[0]) == "chaos" and r[1] not in ids]
        if cold:
            ok = all(r[2] == 503 for r in cold if inj + 10 <= r[0]) and not any(r[2] == 502 for r in cold)
            checks.append((f"chaos: uncached product → 503 + Retry-After, never 502 "
                           f"({sorted(set(r[2] for r in cold))})", ok))
    if "chaos_p95_s" in h:
        p = pct(chaos_lat, 0.95)
        checks.append((f"chaos (after the first 10 s): p95 {p * 1000:.0f} ms < {h['chaos_p95_s'] * 1000:.0f} ms", p < h["chaos_p95_s"]))
    if "min_degraded" in h:
        v, n = ratio("chaos", lambda r: bool(r[3]))
        checks.append((f"chaos: {v:.0%} of orders served degraded from the cache (≥ {h['min_degraded']:.0%})", v >= h["min_degraded"]))
    opens = [t for t, _p, _f, to, _w in transitions if to == "open"]
    if "open_within_s" in h:
        first = min((t for t, _p, _f, to, _w in transitions if to == "open" and t >= inj - 1), default=None)
        ok = first is not None and first - inj <= h["open_within_s"]
        checks.append((f"breaker opened {'%.1f s' % (first - inj) if first is not None else 'never'} after injection "
                       f"(≤ {h['open_within_s']} s)", ok))
    if "close_within_s" in h:
        pods = {p for _t, p, *_r in transitions}
        last_close = []
        for pod in pods:
            ts = [(t, to) for t, p, _f, to, _w in transitions if p == pod]
            final = ts[-1]
            last_close.append(final[0] if final[1] == "closed" else None)
        ok = bool(last_close) and all(c is not None and c - rem <= h["close_within_s"] for c in last_close)
        desc = ", ".join("never" if c is None else f"{c - rem:.1f} s" for c in last_close)
        checks.append((f"every breaker closed again after the fault was removed: {desc} (≤ {h['close_within_s']} s)", ok))
    if h.get("breaker_stays_closed"):
        checks.append((f"breaker stayed closed ({len(opens)} open transitions)", not opens))

    with open(f"{a.out}/summary.txt", "w") as f:
        stamp = dt.datetime.fromtimestamp(t0, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        f.write(f"# {stamp}  chaos experiment {name}: {a.experiment}\n")
        f.write(f"# load: {a.rps:g} POST /api/orders per second via {host}; ids {ids}"
                f"{' + chaos-only ' + a.chaos_ids if a.chaos_ids else ''}\n")
        f.write(f"# phases: baseline 0–{inj}s · chaos {inj}–{rem}s · recovery {rem}–{total}s\n\n")
        f.write("## per phase\n")
        for ph in ("baseline", "chaos", "recovery"):
            rs = [r for r in results if phase_of(r[0]) == ph]
            lat = [r[4] for r in rs]
            codes = {}
            for r in rs:
                codes[r[2]] = codes.get(r[2], 0) + 1
            f.write(f"  {ph:9} orders {len(rs):5}  codes {dict(sorted(codes.items()))}  degraded {sum(bool(r[3]) for r in rs):5}"
                    f"  p50 {pct(lat, .5) * 1000:6.0f} ms  p95 {pct(lat, .95) * 1000:6.0f} ms  max {max(lat, default=0) * 1000:6.0f} ms\n")
        f.write("\n## breaker transitions (orders logs)\n")
        f.write(open(f"{a.out}/transitions.txt").read().split("\n", 1)[1] or "  none\n")
        f.write("\n## Prometheus counters over the run\n" + "\n".join(prom_lines) + "\n")
        f.write("\n## hypothesis\n")
        for text, ok in checks:
            f.write(f"  {'PASS' if ok else 'FAIL'}  {text}\n")
        f.write(f"\nRESULT: {'hypothesis confirmed' if checks and all(ok for _t, ok in checks) else 'hypothesis REJECTED'}\n")
    print(open(f"{a.out}/summary.txt").read())

    # ── chart
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return
    xs = [r["t"] for r in rows]
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(11, 6), sharex=True, gridspec_kw={"height_ratios": [3, 2]})
    ok_fresh = [r["s2xx"] - r["degraded"] for r in rows]
    ax1.stackplot(xs, ok_fresh, [r["degraded"] for r in rows], [r["s5xx"] + r["errors"] for r in rows],
                  [r["s4xx"] + r["s429"] for r in rows],
                  labels=["201 (live price)", "201 degraded (cache)", "5xx / error", "4xx"],
                  colors=["#2a9d8f", "#e9c46a", "#e63946", "#8d99ae"])
    ax1.set_ylabel("orders / s")
    ax1.legend(loc="upper right", fontsize=8, ncol=4)
    ax2.plot(xs, [r["p95"] * 1000 for r in rows], color="#264653", label="p95")
    ax2.plot(xs, [r["max"] * 1000 for r in rows], color="#264653", alpha=0.3, label="max")
    ax2.set_ylabel("latency, ms")
    ax2.set_xlabel("seconds since load start")
    ax2.legend(loc="upper right", fontsize=8)
    for ax in (ax1, ax2):
        ax.axvspan(inj, rem, color="#e63946", alpha=0.07)
        for t, _p, _f, to, _w in transitions:
            ax.axvline(t, color={"open": "#e63946", "half_open": "#f4a261", "closed": "#2a9d8f"}[to],
                       lw=0.8, ls="--", alpha=0.6)
    ax1.set_title(f"{name}: {os.path.basename(a.experiment)} — shaded = fault active; dashed = breaker "
                  "open (red) / half-open (orange) / closed (green)", fontsize=9)
    fig.tight_layout()
    fig.savefig(f"{a.out}/timeline.png", dpi=130)


if __name__ == "__main__":
    sys.exit(main())
