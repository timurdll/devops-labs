"""Week 9 · render the RED dashboard's data for the experiment window, in the dashboard's layout.
Input: docs/week9/exports/grafana-panel-results.json, written by scripts/telemetry-verify.py --export,
which ran every panel query of k8s/observability/dashboards/shoplite-red.json through Grafana's
/api/ds/query (environment = prod). Needs matplotlib.
Usage: python3 dashboard_render.py <results.json> <out.png> <fault-start ISO> <fault-end ISO>"""
import datetime as dt, json, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt

src, out, f0, f1 = sys.argv[1:5]
data = json.load(open(src))["results"]
fault = [dt.datetime.fromisoformat(x.replace("Z", "+00:00")) for x in (f0, f1)]
BG, PANEL, GRID, TXT, MUTED = "#111217", "#181b1f", "#2c3235", "#d8d9da", "#8e8e8e"
PAL = ["#73bf69", "#f2cc0c", "#8ab8ff", "#ff780a", "#f2495c", "#5794f2", "#b877d9", "#fade2a", "#c4162a"]
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 9, "text.color": TXT, "axes.labelcolor": TXT,
                     "xtick.color": MUTED, "ytick.color": MUTED, "axes.edgecolor": GRID})


def series(panel, ref="A"):
    for r in data:
        if r["panel"] == panel and r["refId"] == ref:
            for f in r["frames"]:
                t = [dt.datetime.fromtimestamp(x / 1000, dt.timezone.utc) for x in f["data"]["values"][0]] if "data" in f else \
                    [dt.datetime.fromtimestamp(x / 1000, dt.timezone.utc) for x in f["values"][0]]
                v = f["values"][1] if "values" in f else f["data"]["values"][1]
                lab = next((l for l in f["labels"] if l), {}) or {}
                yield t, [x if x is not None else float("nan") for x in v], lab


def aligned(frames):
    """Put series with different timestamps on one shared grid (missing points = 0) for stacking."""
    import numpy as np
    grid = sorted({x for t, _, _ in frames for x in t})
    idx = {x: i for i, x in enumerate(grid)}
    out = []
    for t, v, lab in frames:
        arr = np.zeros(len(grid))
        for x, y in zip(t, v):
            arr[idx[x]] = 0 if y != y else y
        out.append((grid, arr, lab))
    return out


def style(ax, title, unit=""):
    ax.set_facecolor(PANEL)
    ax.set_title(title, loc="left", color=TXT, fontsize=10.5, fontweight="bold", pad=6)
    ax.grid(color=GRID, linewidth=0.6)
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
    ax.axvspan(fault[0], fault[1], color="#f2495c", alpha=0.12, lw=0)
    if unit:
        ax.set_ylabel(unit, color=MUTED)
    for s in ax.spines.values():
        s.set_visible(False)


fig = plt.figure(figsize=(18, 13.2), facecolor=BG)
gs = fig.add_gridspec(4, 24, height_ratios=[0.55, 1, 1, 0.8], hspace=0.42, wspace=2.6, left=0.03, right=0.99, top=0.92, bottom=0.03)
fig.text(0.03, 0.965, "ShopLite — RED (Rate · Errors · Duration)   ·   environment = prod   ·   service = All", fontsize=15, fontweight="bold", color=TXT)
fig.text(0.03, 0.94, f"Data: Grafana /api/ds/query with the dashboard's own panel queries · window "
         f"11:47–11:55 UTC · shaded = fault injected (catalog scaled to 0, {fault[0]:%H:%M:%S}–{fault[1]:%H:%M:%S})",
         fontsize=9.5, color=MUTED)

# row 1: stat tiles (median before the fault = baseline, worst value during the fault)
tiles = [("Rate", "A", "{:.1f} req/s", "#5794f2", max), ("Errors (5xx ratio)", "A", "{:.1%}", "#73bf69", max),
         ("Duration p95", "A", "{:.0f} ms", "#73bf69", max), ("In-flight requests", "A", "{:.0f}", "#52606D", max)]
for i, (name, ref, fmt, color, agg) in enumerate(tiles):
    ax = fig.add_subplot(gs[0, i * 6:(i + 1) * 6]); ax.axis("off")
    t, v, _ = next(series(name, ref))
    vals = [x for x in v if x == x]
    k = 1000 if "ms" in fmt else 1
    in_fault = [x for tt, x in zip(t, v) if fault[0] <= tt <= fault[1] + dt.timedelta(seconds=60) and x == x]
    peak = agg(in_fault) if in_fault else float("nan")
    end_col = color
    if "Errors" in name:
        end_col = "#73bf69"  # coloured by the baseline; the fault value is in the caption
    ax.add_patch(plt.Rectangle((0, 0), 1, 1, transform=ax.transAxes, color=end_col))
    ax.text(0.04, 0.82, name, transform=ax.transAxes, fontsize=10.5, fontweight="bold", color="white")
    pre = sorted(x for tt, x in zip(t, v) if tt < fault[0] and x == x and tt > t[0] + dt.timedelta(seconds=90))
    baseline = pre[len(pre) // 2] if pre else vals[-1]
    ax.text(0.5, 0.42, fmt.format(baseline * k), transform=ax.transAxes, ha="center", fontsize=24, fontweight="bold", color="white")
    ax.text(0.96, 0.82, "baseline", transform=ax.transAxes, ha="right", fontsize=8.5, color="white")
    ax.text(0.5, 0.1, "during fault: " + fmt.format(peak * k), transform=ax.transAxes, ha="center", fontsize=9.5, color="white")

# row 2
ax = fig.add_subplot(gs[1, 0:8]); style(ax, "Rate by route", "req/s")
for i, (t, v, lab) in enumerate(series("Rate by route")):
    ax.plot(t, v, color=PAL[i], lw=1.6, label=f"{lab.get('service')} {lab.get('http_route')}")
ax.legend(fontsize=7.5, facecolor=PANEL, edgecolor=GRID, labelcolor=TXT, loc="lower left")
ax = fig.add_subplot(gs[1, 8:16]); style(ax, "Errors by status code", "req/s")
frames = list(series("Errors by status code"))
base = None
for i, (t, v, lab) in enumerate(aligned(sorted(frames, key=lambda f: f[2].get("http_response_status_code")))):
    code = lab.get("http_response_status_code")
    col = "#f2495c" if code.startswith("5") else ["#ff9830", "#fade2a", "#b877d9"][i % 3]
    import numpy as np
    arr = np.nan_to_num(np.array(v, dtype=float))
    bottom = base if base is not None else np.zeros_like(arr)
    ax.fill_between(t, bottom, bottom + arr, step="mid", color=col, alpha=0.85, lw=0, label=f"{lab.get('service')} {code}")
    base = bottom + arr
ax.legend(fontsize=7.5, facecolor=PANEL, edgecolor=GRID, labelcolor=TXT, loc="upper left")
ax = fig.add_subplot(gs[1, 16:24]); style(ax, "Duration p50 / p95 / p99", "seconds")
for ref, ls, q in (("A", ":", "p50"), ("B", "-", "p95"), ("C", "--", "p99")):
    for t, v, lab in series("Duration p50 / p95 / p99", ref):
        if lab.get("service") in ("catalog", "orders"):
            ax.plot(t, v, ls=ls, lw=1.5, color="#ff780a" if lab["service"] == "orders" else "#73bf69", label=f"{q} {lab['service']}")
ax.set_yscale("log")
ax.legend(fontsize=7.5, facecolor=PANEL, edgecolor=GRID, labelcolor=TXT, ncol=2, loc="upper left")

# row 3
ax = fig.add_subplot(gs[2, 0:8]); style(ax, "Latency distribution (buckets)")
import numpy as np
hb = sorted(series("Latency distribution (all API requests)"), key=lambda f: float(f[2]["le"]) if f[2]["le"] != "+Inf" else 1e9)
les = [f[2]["le"] for f in hb]
cum = np.array([np.nan_to_num(np.array(f[1], dtype=float)) for f in hb])
per = np.diff(np.vstack([np.zeros(cum.shape[1]), cum]), axis=0).clip(min=0)
tt = mdates.date2num(hb[0][0])
ax.imshow(np.log1p(per), aspect="auto", origin="lower", cmap="inferno", extent=[tt[0], tt[-1], 0, len(les)], interpolation="nearest")
ax.set_yticks(np.arange(len(les)) + 0.5); ax.set_yticklabels(["≤" + l for l in les], fontsize=7)
ax.xaxis_date(); ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
ax = fig.add_subplot(gs[2, 8:16]); style(ax, "orders → catalog (client view)", "req/s")
for i, (t, v, lab) in enumerate(series("orders → catalog (client view)", "A")):
    c = lab.get("http_response_status_code")
    ax.plot(t, v, lw=1.6, color={"200": "#73bf69", "404": "#fade2a", "error": "#f2495c", "timeout": "#b877d9"}.get(c, PAL[i]), label=f"rate {c}")
ax2 = ax.twinx(); ax2.set_ylabel("p95 (s)", color=MUTED); ax2.tick_params(colors=MUTED)
for t, v, _ in series("orders → catalog (client view)", "B"):
    ax2.plot(t, v, ls="--", color="#8ab8ff", lw=1.3, label="p95")
for s in ax2.spines.values():
    s.set_visible(False)
h1, l1 = ax.get_legend_handles_labels(); h2, l2 = ax2.get_legend_handles_labels()
ax.legend(h1 + h2, l1 + l2, fontsize=7.5, facecolor=PANEL, edgecolor=GRID, labelcolor=TXT, loc="center left")
ax = fig.add_subplot(gs[2, 16:24]); style(ax, "Edge (Traefik) requests by code (req/s)")
fr = sorted(series("Edge (Traefik) requests by code"), key=lambda f: f[2].get("code"))
base = None
for t, v, lab in aligned(fr):
    code = lab.get("code"); arr = np.nan_to_num(np.array(v, dtype=float)); bottom = base if base is not None else np.zeros_like(arr)
    col = {"200": "#73bf69", "201": "#56a64b", "404": "#fade2a", "409": "#ff9830", "422": "#ffb357", "502": "#f2495c", "503": "#c4162a"}.get(code, "#8ab8ff")
    ax.fill_between(t, bottom, bottom + arr, color=col, alpha=0.85, lw=0, label=code); base = bottom + arr
ax.legend(fontsize=7.5, facecolor=PANEL, edgecolor=GRID, labelcolor=TXT, ncol=4, loc="lower left")

# row 4: failed traces table
ax = fig.add_subplot(gs[3, 0:24]); ax.axis("off"); ax.set_facecolor(PANEL)
ax.add_patch(plt.Rectangle((0, 0), 1, 1, transform=ax.transAxes, color=PANEL))
ax.text(0.005, 0.9, "Failed traces (Jaeger · k8s.namespace.name=shop-prod error=true)", transform=ax.transAxes, fontsize=10.5, fontweight="bold")
r = next(x for x in data if x["panel"] == "Failed traces")
f = r["frames"][0]; vals = f["values"] if "values" in f else f["data"]["values"]
rows = list(zip(*vals))[:6]
cols = ["Trace ID", "Trace name", "Start time", "Duration"]
for j, c in enumerate(cols):
    ax.text(0.01 + j * 0.25, 0.74, c, transform=ax.transAxes, color=MUTED, fontweight="bold")
for i, row in enumerate(rows):
    y = 0.62 - i * 0.11
    ax.text(0.01, y, row[0], transform=ax.transAxes, color="#8ab8ff", family="DejaVu Sans Mono", fontsize=8.5)
    ax.text(0.26, y, row[1], transform=ax.transAxes)
    ax.text(0.51, y, dt.datetime.fromtimestamp(row[2] / 1000, dt.timezone.utc).strftime("%H:%M:%S.%f")[:-3], transform=ax.transAxes)
    ax.text(0.76, y, f"{row[3] / 1000:,.0f} ms", transform=ax.transAxes, color="#f2495c")
fig.savefig(out, dpi=110, facecolor=BG)
print("wrote", out)
