"""Week 9 · trace waterfall from a REAL trace exported from Jaeger (GET /api/traces/<id> JSON).
Usage: python3 trace_waterfall.py <trace.json> <out.png> "<title>"
Rows are spans in depth-first order (parent before children); bars are positioned on a shared
time axis; each row shows service, operation, duration and span/parent IDs, i.e. exactly the
values carried in the W3C traceparent header: 00-<trace-id>-<parent-span-id>-<flags>."""
import json, os, sys
from PIL import Image, ImageDraw, ImageFont

def font(size, bold=False):
    for name in (["DejaVuSans-Bold.ttf", "Arial Bold.ttf"] if bold else ["DejaVuSans.ttf", "Arial.ttf"]):
        for d in ("/usr/share/fonts/truetype/dejavu", "/System/Library/Fonts/Supplemental", "/Library/Fonts"):
            if os.path.exists(os.path.join(d, name)):
                return ImageFont.truetype(os.path.join(d, name), size)
    return ImageFont.load_default()

def mono(size):
    for p in ("/System/Library/Fonts/Menlo.ttc", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"):
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()

COLORS = {"traefik": "#2E74B5", "orders": "#E69138", "catalog": "#38761D", "web": "#8E44AD"}
src, out, title = sys.argv[1], sys.argv[2], sys.argv[3]
trace = json.load(open(src))["data"][0]
procs = {k: v["serviceName"] for k, v in trace["processes"].items()}
spans = {s["spanID"]: s for s in trace["spans"]}
parent = {s["spanID"]: next((r["spanID"] for r in s.get("references", []) if r["refType"] == "CHILD_OF"), None)
          for s in trace["spans"]}
children = {}
for sid, p in parent.items():
    children.setdefault(p if p in spans else None, []).append(sid)
order = []
def walk(sid, depth):
    order.append((sid, depth))
    for c in sorted(children.get(sid, []), key=lambda x: spans[x]["startTime"]):
        walk(c, depth + 1)
for root in sorted(children.get(None, []), key=lambda x: spans[x]["startTime"]):
    walk(root, 0)

t0 = min(s["startTime"] for s in spans.values())
t1 = max(s["startTime"] + s["duration"] for s in spans.values())
total = t1 - t0
def tag(s, key):
    return next((t["value"] for t in s.get("tags", []) if t["key"] == key), None)

ROW, LEFT, BAR_W, TOP = 34, 640, 900, 120
W, H = LEFT + BAR_W + 60, TOP + ROW * len(order) + 90
img = Image.new("RGB", (W, H), "white"); d = ImageDraw.Draw(img)
F_T, F_B, F_S, F_M = font(24, True), font(15), font(13), mono(13)
d.text((24, 18), title, font=F_T, fill="#1F2933")
d.text((24, 54), f"trace_id {trace['traceID']}  ·  {len(order)} spans  ·  {total / 1000:.2f} ms end-to-end  ·  source: Jaeger API",
       font=F_B, fill="#616E7C")
# axis
for i in range(5):
    x = LEFT + BAR_W * i / 4
    d.line((x, TOP - 8, x, H - 70), fill="#E4E7EB")
    d.text((x, TOP - 26), f"{total * i / 4 / 1000:.1f} ms", font=F_S, fill="#616E7C", anchor="mm")
for i, (sid, depth) in enumerate(order):
    s = spans[sid]; svc = procs[s["processID"]]; y = TOP + i * ROW
    if i % 2 == 0:
        d.rectangle((0, y, W, y + ROW), fill="#F8FAFC")
    color = COLORS.get(svc, "#52606D")
    err = tag(s, "error") in (True, "true") or tag(s, "otel.status_code") == "ERROR"
    kind = tag(s, "span.kind") or ""
    label = f"{svc}  {s['operationName']}"
    d.text((24 + depth * 18, y + 9), ("└ " if depth else "") + label, font=F_B, fill="#C0392B" if err else "#1F2933")
    d.text((LEFT - 190, y + 10), f"{sid[:8]}←{(parent[sid] or '—')[:8]}", font=F_M, fill="#9AA5B1")
    x0 = LEFT + BAR_W * (s["startTime"] - t0) / total
    x1 = max(x0 + 3, LEFT + BAR_W * (s["startTime"] + s["duration"] - t0) / total)
    d.rectangle((x0, y + 8, x1, y + ROW - 8), fill="#C0392B" if err else color)
    txt = f"{s['duration'] / 1000:.2f} ms" + (f" · {kind}" if kind else "") + ("  ERROR" if err else "")
    if x1 + 190 < W:  # label right of the bar
        d.text((x1 + 6, y + 9), txt, font=F_S, fill="#C0392B" if err else "#3E4C59")
    else:  # long bar: label inside it
        d.text((x1 - 8, y + 9), txt, font=F_S, fill="white", anchor="ra")
ly = H - 52
d.text((24, ly), "span ← parent (ids as propagated in traceparent)", font=F_S, fill="#9AA5B1")
x = 420
for svc, c in COLORS.items():
    if svc in procs.values():
        d.rectangle((x, ly + 2, x + 14, ly + 16), fill=c); d.text((x + 20, ly), svc, font=F_S, fill="#1F2933"); x += 110
d.rectangle((x, ly + 2, x + 14, ly + 16), fill="#C0392B"); d.text((x + 20, ly), "error", font=F_S, fill="#1F2933")
img.save(out); print("wrote", out, img.size)
