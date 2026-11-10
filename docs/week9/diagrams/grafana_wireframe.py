"""Week 9 · Grafana dashboard wireframe (low fidelity), drawn on the same 24-column grid as
k8s/observability/dashboards/shoplite-red.json. Run: python3 docs/week9/diagrams/grafana_wireframe.py
Needs Pillow. Output: docs/week9/diagrams/grafana-wireframe.png"""
import os
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "grafana-wireframe.png")
W, COLS, UNIT_H, X0, Y0 = 1800, 24, 34, 40, 150
COLW = (W - 2 * X0) / COLS

def font(size, bold=False):
    for name in (["DejaVuSans-Bold.ttf", "Arial Bold.ttf"] if bold else ["DejaVuSans.ttf", "Arial.ttf"]):
        for d in ("/usr/share/fonts/truetype/dejavu", "/System/Library/Fonts/Supplemental", "/Library/Fonts"):
            p = os.path.join(d, name)
            if os.path.exists(p):
                return ImageFont.truetype(p, size)
    return ImageFont.load_default()

F_T, F_H, F_B, F_S = font(30, True), font(19, True), font(16), font(14)
INK, MUTED, LINE, PANEL, ROWBG = "#1F2933", "#616E7C", "#9AA5B1", "#FFFFFF", "#E4E7EB"
BLUE, GREEN, ORANGE, RED, PURPLE = "#2E74B5", "#38761D", "#E69138", "#C0392B", "#8E44AD"

img = Image.new("RGB", (W, 1500), "#F5F7FA")
d = ImageDraw.Draw(img)

def box(x, y, w, h):  # grid units → pixels
    return (X0 + x * COLW + 4, Y0 + y * UNIT_H + 4, X0 + (x + w) * COLW - 4, Y0 + (y + h) * UNIT_H - 4)

def badge(x, y, n, color):
    d.ellipse((x, y, x + 30, y + 30), fill=color)
    d.text((x + 15, y + 15), str(n), font=F_H, fill="white", anchor="mm")

def panel(x, y, w, h, title, kind, note="", prio=None, color=BLUE):
    l, t, r, b = box(x, y, w, h)
    d.rounded_rectangle((l, t, r, b), 6, fill=PANEL, outline=LINE, width=2)
    d.text((l + 12, t + 10), title, font=F_H, fill=INK)
    if prio:
        badge(r - 40, t + 8, prio, color)
    cl, ct, cr, cb = l + 14, t + 42, r - 14, b - (30 if note else 12)
    if kind == "stat":
        cb = b - 14  # stat tiles carry their caption inside the coloured box
        d.rectangle((cl, ct, cr, cb), fill=color)
        d.text(((cl + cr) / 2, ct + 26), note.split("|")[0], font=F_T, fill="white", anchor="mm")
        d.text(((cl + cr) / 2, cb - 11), note.split("|")[1], font=F_S, fill="white", anchor="mm")
        return
    if kind == "lines":
        for i, c in enumerate([BLUE, GREEN, ORANGE, PURPLE]):
            pts = [(cl + k * (cr - cl) / 12, cb - (cb - ct) * (0.25 + 0.12 * i + 0.08 * ((k * (i + 3)) % 5) / 4)) for k in range(13)]
            d.line(pts, fill=c, width=3)
        if "exemplar" in title.lower() or "p95" in title:
            for k in (2, 5, 9):
                cx, cy = cl + k * (cr - cl) / 12, ct + (cb - ct) * 0.3
                d.rectangle((cx - 5, cy - 5, cx + 5, cy + 5), outline=RED, width=2)
    elif kind == "bars":
        n = 14
        for k in range(n):
            bx = cl + k * (cr - cl) / n
            h1 = (cb - ct) * (0.15 + 0.05 * (k % 3)); h2 = (cb - ct) * (0.5 if 6 <= k <= 9 else 0.05)
            d.rectangle((bx + 3, cb - h1, bx + (cr - cl) / n - 3, cb), fill=ORANGE)
            d.rectangle((bx + 3, cb - h1 - h2, bx + (cr - cl) / n - 3, cb - h1), fill=RED)
    elif kind == "heat":
        rows, cols = 6, 16
        for i in range(rows):
            for k in range(cols):
                v = max(0, 1 - abs(i - 1.5 - (2.5 if 6 <= k <= 9 else 0)) / 2.5)
                shade = int(255 - 150 * v)
                d.rectangle((cl + k * (cr - cl) / cols + 1, ct + i * (cb - ct) / rows + 1,
                             cl + (k + 1) * (cr - cl) / cols - 1, ct + (i + 1) * (cb - ct) / rows - 1),
                            fill=(255, shade, int(shade * 0.7)))
    elif kind == "table":
        cols = ["Trace ID", "Trace name", "Start time", "Duration"]
        cw = (cr - cl) / 4
        d.rectangle((cl, ct, cr, ct + 26), fill=ROWBG)
        for i, c in enumerate(cols):
            d.text((cl + i * cw + 8, ct + 5), c, font=F_S, fill=INK)
        for rrow in range(1, 6):
            yy = ct + 26 + (rrow - 1) * 26
            d.line((cl, yy + 26, cr, yy + 26), fill=ROWBG)
            d.text((cl + 8, yy + 5), "4bf92f35…", font=F_S, fill=BLUE)
            d.text((cl + cw + 8, yy + 5), "traefik: POST", font=F_S, fill=MUTED)
            d.rectangle((cl + 3 * cw + 8, yy + 8, cl + 3 * cw + 8 + 20 * rrow, yy + 18), fill=PURPLE)
    if note:
        d.text((l + 12, b - 26), note, font=F_S, fill=MUTED)

def row(y, text):
    l, t, r, b = box(0, y, 24, 1)
    d.text((l + 4, t + 6), "v  " + text, font=F_H, fill=INK)

# header
d.text((X0, 24), "ShopLite — RED (Rate · Errors · Duration)", font=F_T, fill=INK)
d.text((X0, 66), "Wireframe · 24-column Grafana grid · one screen answers: is it broken? -> where? -> why?", font=F_B, fill=MUTED)
for i, (lab, val) in enumerate([("Environment", "prod  v"), ("Service", "All  v")]):
    x = X0 + i * 260
    d.rounded_rectangle((x, 100, x + 240, 134), 4, fill=PANEL, outline=LINE)
    d.text((x + 10, 108), lab, font=F_S, fill=MUTED); d.text((x + 140, 108), val, font=F_B, fill=INK)
d.rounded_rectangle((W - X0 - 330, 100, W - X0, 134), 4, fill=PANEL, outline=LINE)
d.text((W - X0 - 320, 108), "Last 30 min   |   refresh 10 s", font=F_B, fill=INK)

row(0, "1. RED summary — is it broken?  (API routes only, probes excluded)")
panel(0, 1, 6, 4, "Rate", "stat", "152 req/s|sum rate /api/*", 1, BLUE)
panel(6, 1, 6, 4, "Errors (5xx ratio)", "stat", "0.4 %|SLO < 5 %", 1, GREEN)
panel(12, 1, 6, 4, "Duration p95", "stat", "18 ms|SLO < 500 ms", 1, GREEN)
panel(18, 1, 6, 4, "In-flight requests", "stat", "3|saturation hint", None, "#52606D")
row(5, "2. Rate · Errors · Duration per route — where?")
panel(0, 6, 8, 8, "Rate by route", "lines", "service × http_route (bounded labels)", 2, BLUE)
panel(8, 6, 8, 8, "Errors by status code", "bars", "stacked 4xx (orange) / 5xx (red)", 2, RED)
panel(16, 6, 8, 8, "Duration p50 / p95 / p99", "lines", "squares = exemplars -> click opens the trace", 2, GREEN)
row(14, "3. Dependencies and edge — whose fault?")
panel(0, 15, 8, 8, "Latency distribution", "heat", "histogram buckets (bimodal latency)", 3, ORANGE)
panel(8, 15, 8, 8, "orders -> catalog (client view)", "lines", "rate by response + p95 (right axis)", 3, ORANGE)
panel(16, 15, 8, 8, "Edge (Traefik) requests by code", "bars", "what the user saw, incl. web", 3, ORANGE)
row(23, "4. Traces (Jaeger) — why?")
panel(0, 24, 12, 9, "Recent orders traces", "table", "Jaeger search · k8s.namespace.name=shop-$env", 4, PURPLE)
panel(12, 24, 12, 9, "Failed traces", "table", "Jaeger search · error=true", 4, PURPLE)

# legend
ly = Y0 + 33 * UNIT_H + 16
d.text((X0, ly), "Reading order (priority):", font=F_H, fill=INK)
for i, (c, t) in enumerate([(BLUE, "1  RED tiles: SLO colour at a glance"), (RED, "2  per-route RED: locate the failing route"),
                            (ORANGE, "3  dependency + edge: upstream vs. downstream"), (PURPLE, "4  traces: root cause in one request")]):
    x = X0 + 260 + (i % 2) * 560; yy = ly + (i // 2) * 30
    d.rectangle((x, yy + 4, x + 18, yy + 22), fill=c); d.text((x + 26, yy + 2), t, font=F_B, fill=INK)

img = img.crop((0, 0, W, ly + 80))
img.save(OUT)
print("wrote", OUT, img.size)
