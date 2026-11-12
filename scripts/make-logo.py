"""Writes the Solaris mark (landing/logo.svg) and its square icon variants.

The mark is a lightning bolt made of a solar panel: a 3x3 grid of cells turned
-41.5 degrees, with a wedge off its top-right corner and the same wedge, turned
half a turn, off its bottom-left corner.

    python3 scripts/make-logo.py              # SVGs and every PNG (needs Pillow and Chrome)
    python3 scripts/make-logo.py --svg-only   # just the SVGs

Then rebuild the web app (scripts/build-web.sh) and the APK (scripts/build-apk.sh) so
landing/app/ and downloads/solaris.apk carry the new icons.
"""
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CELL_W, CELL_H = 20.0, 31.0       # one solar cell, before the turn
GAP = 2.0                         # between cells, and between the grid and the wedges
CELL_R = 1.8                      # cell corner radius
WEDGE_LEG = 47.0                  # the wedge's long leg, along the grid's top edge
WEDGE_R = 1.6                     # wedge corner radius
ANGLE = -41.5                     # degrees

W, H = 3 * CELL_W, 3 * CELL_H


def rot(p):
    a = math.radians(ANGLE)
    x, y = p
    return (x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a))


def inset(poly, r):
    """Offsets a convex, clockwise (y down) polygon inward by r."""
    n = len(poly)
    lines = []
    for i in range(n):
        (x1, y1), (x2, y2) = poly[i], poly[(i + 1) % n]
        dx, dy = x2 - x1, y2 - y1
        L = math.hypot(dx, dy)
        nx, ny = -dy / L, dx / L      # inward normal for clockwise order in y-down space
        lines.append(((x1 + nx * r, y1 + ny * r), (dx, dy)))
    out = []
    for i in range(n):
        (p, d), (q, e) = lines[i - 1], lines[i]
        den = d[0] * e[1] - d[1] * e[0]
        t = ((q[0] - p[0]) * e[1] - (q[1] - p[1]) * e[0]) / den
        out.append((p[0] + d[0] * t, p[1] + d[1] * t))
    return out


# the wedges, in the grid's own frame (x along the cell's width, y along its height)
top_wedge = [(W + GAP, 0.0), (W + GAP + WEDGE_LEG, 0.0), (W + GAP, (H - 2 * GAP) / 3)]
bottom_wedge = [(W - x, H - y) for x, y in top_wedge]

cw, ch = (W - 2 * GAP) / 3, (H - 2 * GAP) / 3
cells = [(i * (cw + GAP), j * (ch + GAP), cw, ch) for i in range(3) for j in range(3)]

# bounds after the turn
pts = [rot(p) for p in top_wedge + bottom_wedge]
pts += [rot((x, y)) for x, y, w, h in cells for x, y in ((x, y), (x + w, y), (x, y + h), (x + w, y + h))]
minx, maxx = min(p[0] for p in pts), max(p[0] for p in pts)
miny, maxy = min(p[1] for p in pts), max(p[1] for p in pts)
PAD = 1.0
vb = (minx - PAD, miny - PAD, maxx - minx + 2 * PAD, maxy - miny + 2 * PAD)


def f(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def wedge_path(poly):
    ins = inset(poly, WEDGE_R)
    return "M" + "L".join(f"{f(x)} {f(y)}" for x, y in ins) + "Z"


def mark_body(prefix=""):
    """The mark's defs and shapes, in the grid's frame; the caller turns it."""
    cell_rects = "".join(
        f'<rect x="{f(x)}" y="{f(y)}" width="{f(w)}" height="{f(h)}" rx="{f(CELL_R)}"/>' for x, y, w, h in cells
    )
    # the top wedge's gradient runs from its tip (bright) to its base by the grid (deeper)
    tx, ty = W + GAP + WEDGE_LEG, 0.0
    bx, by = W + GAP, CELL_H / 2
    defs = (
        f'<defs>'
        f'<linearGradient id="{prefix}cell" x1="0" y1="0" x2="1" y2="1">'
        f'<stop offset="0" stop-color="#FF9A40"/><stop offset="1" stop-color="#FF7A1E"/></linearGradient>'
        f'<linearGradient id="{prefix}wt" gradientUnits="userSpaceOnUse" x1="{f(tx)}" y1="{f(ty)}" x2="{f(bx)}" y2="{f(by)}">'
        f'<stop offset="0" stop-color="#FB7A1A"/><stop offset="1" stop-color="#DE6414"/></linearGradient>'
        f'<linearGradient id="{prefix}wb" gradientUnits="userSpaceOnUse" x1="{f(W - tx)}" y1="{f(H - ty)}" x2="{f(W - bx)}" y2="{f(H - by)}">'
        f'<stop offset="0" stop-color="#FB7A1A"/><stop offset="1" stop-color="#DE6414"/></linearGradient>'
        f'</defs>'
    )
    stroke = f'stroke-width="{f(2 * WEDGE_R)}" stroke-linejoin="round"'
    shapes = (
        f'<g fill="url(#{prefix}cell)">{cell_rects}</g>'
        f'<path d="{wedge_path(top_wedge)}" fill="url(#{prefix}wt)" stroke="url(#{prefix}wt)" {stroke}/>'
        f'<path d="{wedge_path(bottom_wedge)}" fill="url(#{prefix}wb)" stroke="url(#{prefix}wb)" {stroke}/>'
    )
    return defs, shapes


def logo_svg():
    defs, shapes = mark_body()
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{" ".join(f(v) for v in vb)}">'
        f'<title>Solaris</title>{defs}<g transform="rotate({f(ANGLE)})">{shapes}</g></svg>\n'
    )


def icon_svg(size=512, mark_height=0.78, bg=None, radius=0):
    """A square icon with the mark centred. bg None leaves it transparent."""
    defs, shapes = mark_body()
    scale = size * mark_height / vb[3]
    cx, cy = vb[0] + vb[2] / 2, vb[1] + vb[3] / 2
    back = f'<rect width="{size}" height="{size}" rx="{radius}" fill="{bg}"/>' if bg else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" width="{size}" height="{size}">'
        f'{defs}{back}<g transform="translate({f(size / 2)} {f(size / 2)}) scale({scale:.4f}) '
        f'translate({f(-cx)} {f(-cy)}) rotate({f(ANGLE)})">{shapes}</g></svg>\n'
    )


CREAM = "#FFF8F0"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# name -> (svg, sizes and where each goes)
RES = "app/android/app/src/main/res"
PNGS = {
    # transparent mark, as large as the square allows: browser tabs
    "favicon": (dict(mark_height=0.98), [(16, "app/web/favicon.png"), (32, "landing/favicon-32.png")]),
    # cream tile, full bleed: PWA icons, iOS home screen (it rounds the corners itself)
    "icon": (dict(mark_height=0.76, bg=CREAM), [
        (192, "app/web/icons/Icon-192.png"), (512, "app/web/icons/Icon-512.png"),
        (180, "landing/apple-touch-icon.png"), (180, "app/web/icons/apple-touch-icon.png"),
    ]),
    # cream tile with the mark inside the 80% safe circle: maskable PWA icons
    "maskable": (dict(mark_height=0.62, bg=CREAM), [
        (192, "app/web/icons/Icon-maskable-192.png"), (512, "app/web/icons/Icon-maskable-512.png"),
    ]),
    # Android's legacy launcher icon: a rounded cream tile
    "launcher": (dict(mark_height=0.70, bg=CREAM, radius=112), [
        (48, f"{RES}/mipmap-mdpi/ic_launcher.png"), (72, f"{RES}/mipmap-hdpi/ic_launcher.png"),
        (96, f"{RES}/mipmap-xhdpi/ic_launcher.png"), (144, f"{RES}/mipmap-xxhdpi/ic_launcher.png"),
        (192, f"{RES}/mipmap-xxxhdpi/ic_launcher.png"),
    ]),
    # Android 8+ adaptive icon foreground (108dp, the mark inside the 66dp safe zone)
    "foreground": (dict(mark_height=0.54), [
        (108, f"{RES}/mipmap-mdpi/ic_launcher_foreground.png"), (162, f"{RES}/mipmap-hdpi/ic_launcher_foreground.png"),
        (216, f"{RES}/mipmap-xhdpi/ic_launcher_foreground.png"), (324, f"{RES}/mipmap-xxhdpi/ic_launcher_foreground.png"),
        (432, f"{RES}/mipmap-xxxhdpi/ic_launcher_foreground.png"),
    ]),
}


def render(svg_text, tmp):
    """Renders a 512px SVG to a 1024px transparent PNG with headless Chrome."""
    import subprocess
    src, png = tmp / "icon.html", tmp / "icon.png"
    src.write_text(f'<html><body style="margin:0">'
                   f'<div style="width:1024px;height:1024px">{svg_text.replace(chr(10), "")}</div></body></html>'
                   .replace('width="512" height="512"', 'width="1024" height="1024"', 1))
    subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", "--default-background-color=00000000",
                    "--window-size=1024,1024", f"--screenshot={png}", src.as_uri()],
                   check=True, capture_output=True)
    return png


if __name__ == "__main__":
    import sys
    import tempfile

    for path in ("landing/logo.svg", "app/web/logo.svg"):   # the landing nav, the web app's splash
        (ROOT / path).write_text(logo_svg())
    for path in ("landing/favicon.svg", "app/web/favicon.svg"):
        (ROOT / path).write_text(icon_svg(**PNGS["favicon"][0]))
    if "--svg-only" in sys.argv:
        sys.exit()

    from PIL import Image  # pip install pillow; Chrome rasterizes, Pillow scales down

    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        for name, (opts, targets) in PNGS.items():
            big = Image.open(render(icon_svg(**opts), tmp)).convert("RGBA").crop((0, 0, 1024, 1024))
            for size, path in targets:
                img = big.resize((size, size), Image.LANCZOS)
                if "bg" in opts and "radius" not in opts:
                    img = img.convert("RGB")      # full-bleed tiles need no alpha
                (ROOT / path).parent.mkdir(parents=True, exist_ok=True)
                img.save(ROOT / path, optimize=True)
                print(f"{size:>4}  {path}")
