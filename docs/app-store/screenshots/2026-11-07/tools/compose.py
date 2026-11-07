"""Composes an App Store screenshot: headline, subline and a native capture in
a drawn device frame on one brand colour. Adapted from Memex's 3.0 composer
(docs/app-store/assets/3.0-screenshots/tools/compose.py in the memex repo).

  python compose.py --device iphone-landscape --shot raw.png --headline "..." --subline "..." \
      --bg "#6541aa" --out 01.png

Devices: iphone (1320x2868), iphone-landscape (2868x1320), ipad-landscape (2752x2064).
Needs Pillow and the SF Pro variable font.
"""
import argparse
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageOps

FONT = "/Users/10x/Library/Fonts/SFNS.ttf"
TEXT = (255, 255, 255)

SPECS = {
    # Portrait: the screen is sized by width. Landscape: by height.
    "iphone": dict(W=1320, H=2868, screen_w=1000, top=600, bezel=26, dev_r=150, scr_r=126, island="top",
                   text_top=60, text_w=1200, head_size=104, sub_size=50, gap=28),
    "iphone-landscape": dict(W=2868, H=1320, screen_h=900, top=350, bezel=24, dev_r=140, scr_r=118, island="left",
                             text_top=40, text_w=2500, head_size=104, sub_size=50, gap=22),
    "ipad-landscape": dict(W=2752, H=2064, screen_h=1440, top=520, bezel=32, dev_r=96, scr_r=70, island=None,
                           text_top=60, text_w=2400, head_size=132, sub_size=62, gap=28),
}


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_axes([100, 96 if size >= 96 else 28, 400, weight])
    return f


def wrap(draw, text, f, max_w):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = f"{cur} {w}".strip()
        if draw.textlength(t, font=f) <= max_w:
            cur = t
        else:
            lines.append(cur)
            cur = w
    lines.append(cur)
    return lines


def balanced(draw, text, f, max_w):
    """Wrap, then even out line lengths so a two-line headline isn't lopsided."""
    lines = wrap(draw, text, f, max_w)
    if len(lines) < 2:
        return lines
    best, widest, w = lines, max(draw.textlength(l, font=f) for l in lines), max_w
    while w > max_w * 0.5:
        w -= 20
        trial = wrap(draw, text, f, w)
        if len(trial) > len(lines):
            break
        tw = max(draw.textlength(l, font=f) for l in trial)
        if tw < widest:
            best, widest = trial, tw
    return best


def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def compose(a):
    s = SPECS[a.device]
    W, H = s["W"], s["H"]
    bg = hex_rgb(a.bg)
    sub_rgb = tuple(min(255, int(c * 0.25 + 255 * 0.75)) for c in bg)
    canvas = Image.new("RGB", (W, H), bg)
    d = ImageDraw.Draw(canvas)

    hf, sf = font(s["head_size"], 720), font(s["sub_size"], 460)
    head = balanced(d, a.headline, hf, s["text_w"])
    sub = balanced(d, a.subline, sf, s["text_w"])
    head_step, sub_step = int(s["head_size"] * 1.08), int(s["sub_size"] * 1.3)
    block = len(head) * head_step + s["gap"] + len(sub) * sub_step
    band_top, band_bottom = s["text_top"], s["top"] - 20
    y = band_top + max(0, (band_bottom - band_top - block) // 2)
    for line in head:
        d.text((W // 2, y), line, font=hf, fill=TEXT, anchor="mt")
        y += head_step
    y += s["gap"]
    for line in sub:
        d.text((W // 2, y), line, font=sf, fill=sub_rgb, anchor="mt")
        y += sub_step
    if y > s["top"] - 10:
        raise SystemExit(f"text runs into the device: {y} > {s['top'] - 10}")

    # XCUITest landscape captures carry an EXIF orientation; apply it.
    shot = ImageOps.exif_transpose(Image.open(a.shot)).convert("RGB")
    if "screen_w" in s:
        sw = s["screen_w"]
        sh = round(shot.height * sw / shot.width)
    else:
        sh = s["screen_h"]
        sw = round(shot.width * sh / shot.height)
    shot = shot.resize((sw, sh), Image.LANCZOS)

    top, bz = s["top"], s["bezel"]
    dw, dh = sw + 2 * bz, sh + 2 * bz
    dx = (W - dw) // 2

    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle([dx, top + 30, dx + dw, top + dh + 30], radius=s["dev_r"], fill=110)
    shadow = shadow.filter(ImageFilter.GaussianBlur(60))
    canvas = Image.composite(Image.new("RGB", (W, H), tuple(int(c * 0.55) for c in bg)), canvas, shadow)

    device = Image.new("RGBA", (dw, dh), (0, 0, 0, 0))
    dd = ImageDraw.Draw(device)
    dd.rounded_rectangle([0, 0, dw - 1, dh - 1], radius=s["dev_r"], fill=(44, 44, 48, 255))
    dd.rounded_rectangle([4, 4, dw - 5, dh - 5], radius=s["dev_r"] - 4, fill=(16, 16, 18, 255))
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh - 1], radius=s["scr_r"], fill=255)
    device.paste(shot, (bz, bz), mask)
    if s["island"] == "top":
        iw, ih = round(sw * 0.31), round(sw * 0.092)
        ix = (dw - iw) // 2
        dd.rounded_rectangle([ix, bz + round(sw * 0.028), ix + iw, bz + round(sw * 0.028) + ih], radius=ih // 2,
                             fill=(0, 0, 0, 255))
    elif s["island"] == "left":
        iw, ih = round(sh * 0.092), round(sh * 0.31)
        iy = (dh - ih) // 2
        dd.rounded_rectangle([bz + round(sh * 0.028), iy, bz + round(sh * 0.028) + iw, iy + ih], radius=iw // 2,
                             fill=(0, 0, 0, 255))
    canvas.paste(device, (dx, top), device)
    if dh + top > H:
        raise SystemExit(f"device runs off the canvas: {top + dh} > {H}")

    canvas.save(a.out, "PNG", optimize=True)
    print(a.out, canvas.size, canvas.mode)


p = argparse.ArgumentParser()
p.add_argument("--device", choices=SPECS, required=True)
p.add_argument("--shot", required=True)
p.add_argument("--headline", required=True)
p.add_argument("--subline", required=True)
p.add_argument("--bg", required=True)
p.add_argument("--out", required=True)
compose(p.parse_args())
