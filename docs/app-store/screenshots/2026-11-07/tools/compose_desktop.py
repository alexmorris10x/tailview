"""Builds the demo Mac desktop frames that demo_mac_host.py streams.

A 1440x900-point (2880x1800 px) desktop: the macOS Sonoma wallpaper, the real
menu bar of the front app (captured), battery, Control Center and a 9:41 clock,
a Dock of real app icons, a drawn arrow cursor, and real window captures
(`screencapture -l`) of Keynote, TextEdit and QuickTime Player holding neutral
demo content. Each frame is then reduced the way TailView Mac's capture does:
1280 px wide at JPEG quality 0.55, or 1024 px at 0.42 while Mac sound is on.

  python compose_desktop.py <capture dir> <out dir>

<capture dir> holds sonoma.png, mb-battery.png, mb-cc.png, menubar-<app>.png,
<app>-active.png / <app>-inactive.png window captures and <name>.png Dock icons.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 2  # pixels per point
W, H = 1440 * S, 900 * S
MENU = 30 * S
FONT = "/Users/10x/Library/Fonts/SFNS.ttf"
src, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_axes([100, 28, 400, weight])
    return f


def wallpaper():
    wp = Image.open(src / "sonoma.png").convert("RGB")
    scale = W / wp.width
    wp = wp.resize((W, round(wp.height * scale)), Image.LANCZOS)
    top = (wp.height - H) // 3
    return wp.crop((0, top, W, top + H))


def window(name, state):
    img = Image.open(src / f"{name}-{state}.png").convert("RGBA")
    # The opaque window body, inside the captured shadow.
    body = img.getchannel("A").point(lambda a: 255 if a > 250 else 0).getbbox()
    return img, body


def place(canvas, name, state, x, y):
    """Pastes a captured window with its window frame at (x, y) points."""
    img, body = window(name, state)
    canvas.alpha_composite(img, (x * S - body[0], y * S - body[1]))


def menubar(canvas, app):
    d = ImageDraw.Draw(canvas)
    d.rectangle([0, 0, W, MENU], fill=(0, 0, 0, 255))
    left = Image.open(src / f"menubar-{app}.png").convert("RGBA")
    canvas.alpha_composite(left.crop((0, 0, left.width, MENU)), (0, 0))
    clock = "Sat Nov 7  9:41"
    f = font(13 * S, 500)
    tw = d.textlength(clock, font=f)
    x = W - 14 * S - tw
    d.text((x, MENU // 2), clock, font=f, fill=(255, 255, 255, 255), anchor="lm")
    cc = Image.open(src / "mb-cc.png").convert("RGBA")
    x -= 14 * S + cc.width
    canvas.alpha_composite(cc, (int(x), 0))
    bat = Image.open(src / "mb-battery.png").convert("RGBA")
    x -= 10 * S + bat.width
    canvas.alpha_composite(bat, (int(x), 0))


DOCK = ["Finder", "Apps", "Safari", "Mail", "Photos", "Notes", "Music",
        "Keynote", "Pages", "TextEdit", "QuickTime", "AppStore", "Settings", "|", "Trash"]
RUNNING = {"Finder", "Keynote", "TextEdit", "QuickTime"}


def dock(canvas):
    icon, gap, pad = 52 * S, 2 * S, 6 * S
    sep = 14 * S
    n = sum(1 for i in DOCK if i != "|")
    width = n * icon + (n - 1) * gap + sep + 2 * pad
    height = icon + 2 * pad
    x0, y0 = (W - width) // 2, H - height - 5 * S
    radius = 20 * S
    # Frosted glass: blurred wallpaper under a dark tint and a hairline.
    region = canvas.crop((x0, y0, x0 + width, y0 + height)).filter(ImageFilter.GaussianBlur(24))
    tint = Image.new("RGBA", region.size, (38, 38, 42, 150))
    region = Image.alpha_composite(region, tint)
    mask = Image.new("L", region.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, width - 1, height - 1], radius=radius, fill=255)
    canvas.paste(region, (x0, y0), mask)
    ImageDraw.Draw(canvas).rounded_rectangle([x0, y0, x0 + width - 1, y0 + height - 1], radius=radius,
                                             outline=(255, 255, 255, 46), width=S)
    x = x0 + pad
    d = ImageDraw.Draw(canvas)
    for name in DOCK:
        if name == "|":
            d.line([(x + sep // 2 - gap // 2, y0 + 12 * S), (x + sep // 2 - gap // 2, y0 + height - 12 * S)],
                   fill=(255, 255, 255, 60), width=S)
            x += sep
            continue
        img = Image.open(src / f"{name}.png").convert("RGBA").resize((icon, icon), Image.LANCZOS)
        canvas.alpha_composite(img, (x, y0 + pad))
        if name in RUNNING:
            cx = x + icon // 2
            d.ellipse([cx - 2 * S, y0 + height - 4 * S, cx + 2 * S, y0 + height], fill=(235, 235, 235, 230))
        x += icon + gap


def cursor(canvas, x, y):
    """The standard macOS arrow, tip at (x, y) points."""
    pts = [(0, 0), (0, 16.5), (4, 12.8), (6.8, 19.2), (9.3, 18.1), (6.6, 11.9), (11.9, 11.9)]
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    poly = [((x + px) * S, (y + py) * S) for px, py in pts]
    shadow = [((x + px + 0.6) * S, (y + py + 1.2) * S) for px, py in pts]
    d.polygon(shadow, fill=(0, 0, 0, 90))
    layer = layer.filter(ImageFilter.GaussianBlur(S))
    d = ImageDraw.Draw(layer)
    d.polygon(poly, fill=(0, 0, 0, 255), outline=(255, 255, 255, 255), width=int(1.2 * S))
    canvas.alpha_composite(layer)


def frame(name, front, layout, pointer):
    canvas = wallpaper().convert("RGBA")
    for app, state, x, y in layout:
        place(canvas, app, state, x, y)
    menubar(canvas, front)
    dock(canvas)
    cursor(canvas, *pointer)
    full = canvas.convert("RGB")
    full.save(out / f"{name}-full.png")
    for label, width, quality in (("sound-off", 1280, 55), ("sound-on", 1024, 42)):
        small = full.resize((width, width * H // W), Image.LANCZOS)
        small.save(out / f"{name}-{label}.jpg", "JPEG", quality=quality)
    print(name)


frame("keynote", "keynote",
      [("textedit", "inactive", 812, 150), ("keynote", "active", 110, 58)],
      (640, 430))
frame("textedit", "textedit",
      [("keynote", "inactive", 70, 50), ("textedit", "active", 700, 130)],
      (1030, 520))
frame("quicktime", "quicktime",
      [("keynote", "inactive", 70, 50), ("quicktime", "active", 80, 64)],
      (760, 560))
