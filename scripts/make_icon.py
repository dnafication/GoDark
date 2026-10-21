#!/usr/bin/env python3
"""Draws the GoDark app icon and writes every size into AppIcon.appiconset.

Requires Pillow (`pip3 install pillow`). Run from anywhere:
    python3 scripts/make_icon.py
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4096  # draw at 4x of 1024 and downsample for smooth edges
K = S / 1024
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CLEAR = (0, 0, 0, 0)


def px(v):
    return int(round(v * K))


def vertical_gradient(top, bottom):
    grad = Image.new("RGBA", (1, S))
    for y in range(S):
        t = y / (S - 1)
        grad.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(4)))
    return grad.resize((S, S))


def rounded_mask(box, radius):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle([px(v) for v in box], radius=px(radius), fill=255)
    return m


def composite(base, layer, mask):
    base.alpha_composite(Image.composite(layer, Image.new("RGBA", (S, S), CLEAR), mask))


canvas = Image.new("RGBA", (S, S), CLEAR)

# Drop shadow under the tile (macOS icon grid: 824pt tile centered on 1024).
shadow = Image.new("RGBA", (S, S), CLEAR)
ImageDraw.Draw(shadow).rounded_rectangle([px(v) for v in (100, 112, 924, 936)], radius=px(185), fill=(0, 0, 0, 110))
canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(px(14))))

# Background: deep midnight gradient.
tile_mask = rounded_mask((100, 100, 924, 924), 185)
composite(canvas, vertical_gradient((52, 48, 140, 255), (8, 9, 30, 255)), tile_mask)

# Soft violet glow behind the monitor.
glow = Image.new("RGBA", (S, S), CLEAR)
ImageDraw.Draw(glow).ellipse([px(v) for v in (230, 210, 794, 700)], fill=(130, 110, 255, 90))
composite(canvas, glow.filter(ImageFilter.GaussianBlur(px(90))), tile_mask)

d = ImageDraw.Draw(canvas)

# Monitor stand.
d.polygon([(px(470), px(690)), (px(554), px(690)), (px(574), px(782)), (px(450), px(782))], fill=(150, 156, 190, 255))
d.rounded_rectangle([px(v) for v in (372, 772, 652, 800)], radius=px(14), fill=(185, 190, 220, 255))

# Monitor bezel (light aluminium) and screen.
composite(canvas, vertical_gradient((222, 226, 245, 255), (150, 156, 190, 255)), rounded_mask((212, 262, 812, 702), 44))
screen_mask = rounded_mask((238, 288, 786, 676), 24)
composite(canvas, vertical_gradient((28, 30, 78, 255), (4, 5, 18, 255)), screen_mask)

# Stars on the screen.
stars = Image.new("RGBA", (S, S), CLEAR)
sd = ImageDraw.Draw(stars)
for x, y, r in [(330, 360, 7), (420, 590, 5), (690, 370, 6), (720, 600, 8), (300, 520, 4), (640, 320, 4), (370, 450, 3)]:
    sd.ellipse([px(x - r), px(y - r), px(x + r), px(y + r)], fill=(255, 255, 255, 230))
composite(canvas, stars, screen_mask)

# Crescent moon: a full disc minus an offset disc, with a warm glow.
cx, cy, r = 512, 482, 128
moon = Image.new("L", (S, S), 0)
ImageDraw.Draw(moon).ellipse([px(cx - r), px(cy - r), px(cx + r), px(cy + r)], fill=255)
cut = Image.new("L", (S, S), 0)
ImageDraw.Draw(cut).ellipse([px(cx - r + 66), px(cy - r - 44), px(cx + r + 66), px(cy + r - 44)], fill=255)
crescent = ImageChops.subtract(moon, cut)

moon_glow = Image.new("RGBA", (S, S), (255, 214, 120, 0))
moon_glow.putalpha(crescent.filter(ImageFilter.GaussianBlur(px(30))).point(lambda a: int(a * 0.55)))
composite(canvas, moon_glow, screen_mask)
composite(canvas, vertical_gradient((255, 236, 170, 255), (255, 186, 92, 255)), crescent)

# Subtle glass highlight across the top of the screen.
shine = Image.new("RGBA", (S, S), CLEAR)
ImageDraw.Draw(shine).polygon([(px(238), px(288)), (px(786), px(288)), (px(786), px(330)), (px(238), px(440))], fill=(255, 255, 255, 18))
composite(canvas, shine, screen_mask)

icon = canvas.resize((1024, 1024), Image.LANCZOS)

out_dir = os.path.join(ROOT, "GoDark", "Assets.xcassets", "AppIcon.appiconset")
contents_path = os.path.join(out_dir, "Contents.json")
with open(contents_path) as f:
    contents = json.load(f)

for image in contents["images"]:
    base = int(image["size"].split("x")[0])
    scale = int(image["scale"][0])
    name = f"icon_{image['size']}@{scale}x.png"
    icon.resize((base * scale, base * scale), Image.LANCZOS).save(os.path.join(out_dir, name))
    image["filename"] = name

with open(contents_path, "w") as f:
    json.dump(contents, f, indent=2)
    f.write("\n")

os.makedirs(os.path.join(ROOT, "docs"), exist_ok=True)
icon.save(os.path.join(ROOT, "docs", "icon.png"))
print("Icon written to", os.path.normpath(out_dir))
