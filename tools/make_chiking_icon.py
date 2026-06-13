# 치킹! 앱 아이콘 — 의성어("치킹!") + 스티커(펀칭 우표) 리브랜딩.
# 1024×1024, 알파 없는 RGB PNG (iOS 앱 아이콘 요건).
#
# 구성: 따뜻한 그라데이션 배경 → 만화 폭발(스타버스트) → 톱니(펀칭) 테두리의
# 흰 스티커가 비스듬히 붙고 → 그 위에 "치킹!" 의성어 + 임팩트 라인.

import math
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2048                       # supersample, downscale to 1024 at the end
FONT = "/System/Library/Fonts/AppleSDGothicNeo.ttc"

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# --- background: warm amber → coral diagonal gradient -----------------------
TOP, BOTTOM = (255, 205, 66), (255, 102, 74)
bg = Image.new("RGB", (S, S))
px = bg.load()
for y in range(S):
    row = lerp(TOP, BOTTOM, y / (S - 1))
    for x in range(0, S, 8):           # blocky fill, smoothed by downscale
        for dx in range(8):
            px[min(x + dx, S - 1), y] = row
canvas = bg.convert("RGBA")

# --- comic starburst behind the sticker -------------------------------------
def starburst(draw, cx, cy, r_out, r_in, points, fill, rot=0.0):
    pts = []
    for i in range(points * 2):
        ang = rot + math.pi * i / points
        r = r_out if i % 2 == 0 else r_in
        pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
    draw.polygon(pts, fill=fill)

over = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(over)
starburst(d, S * 0.5, S * 0.52, S * 0.46, S * 0.355, 14, (47, 36, 56, 255), rot=0.22)
canvas.alpha_composite(over)

# --- sticker: white pad with stamp-perforation edges -------------------------
W = H = int(S * 0.62)
r_hole = int(W * 0.035)               # perforation bite radius
pad = r_hole + 6                      # holes sit ON the edge; keep them inside the layer
layer = Image.new("RGBA", (W + 2 * pad, H + 2 * pad), (0, 0, 0, 0))
mask = Image.new("L", layer.size, 0)
md = ImageDraw.Draw(mask)
md.rounded_rectangle([pad, pad, pad + W, pad + H], radius=int(W * 0.06), fill=255)

def bite(cx, cy):                     # one perforation hole on the edge
    md.ellipse([cx - r_hole, cy - r_hole, cx + r_hole, cy + r_hole], fill=0)

N = 7
for i in range(1, N + 1):
    t = i / (N + 1)
    bite(pad + W * t, pad)            # top
    bite(pad + W * t, pad + H)        # bottom
    bite(pad, pad + H * t)            # left
    bite(pad + W, pad + H * t)        # right

white = Image.new("RGBA", layer.size, (255, 252, 246, 255))
layer = Image.composite(white, layer, mask)

# --- the symbol: a punched hole — the 치킹! moment, no words -------------------
# A big circular hole bitten clean out of the sticker (the dark burst shows
# through), with the punched-out chip flying off to the upper-right.
hole_r = int(W * 0.215)
hcx, hcy = pad + W * 0.46, pad + H * 0.54
md2 = ImageDraw.Draw(mask)
md2.ellipse([hcx - hole_r, hcy - hole_r, hcx + hole_r, hcy + hole_r], fill=0)
# re-apply the mask now that the hole is punched
layer = Image.composite(white, Image.new("RGBA", layer.size, (0, 0, 0, 0)), mask)
ld = ImageDraw.Draw(layer)
# a soft inner rim so the hole reads as cut paper, not a flat dot
rim = int(W * 0.012)
ld.ellipse([hcx - hole_r - rim, hcy - hole_r - rim,
            hcx + hole_r + rim, hcy + hole_r + rim],
           outline=(222, 210, 196, 255), width=rim)

# --- rotate, shadow, place ----------------------------------------------------
rot = layer.rotate(-7, expand=True, resample=Image.BICUBIC)
shadow = Image.new("RGBA", rot.size, (0, 0, 0, 0))
shadow.paste((20, 10, 20, 110), mask=rot.split()[3])
shadow = shadow.filter(ImageFilter.GaussianBlur(26))
ox = (S - rot.width) // 2
oy = int((S - rot.height) // 2 + S * 0.015)
canvas.alpha_composite(shadow, (ox + 14, oy + 40))
canvas.alpha_composite(rot, (ox, oy))

# --- the punched-out chip, flying off to the upper-right ----------------------
chip_r = int(W * 0.215 * 0.96)
chip = Image.new("RGBA", (chip_r * 2 + 80, chip_r * 2 + 80), (0, 0, 0, 0))
cd = ImageDraw.Draw(chip)
cc = chip_r + 40
cd.ellipse([cc - chip_r, cc - chip_r, cc + chip_r, cc + chip_r],
           fill=(255, 252, 246, 255))
# a quiet lower-left crescent so the chip reads as a tumbling paper disc
inset = int(chip_r * 0.16)
cd.ellipse([cc - chip_r + inset, cc - chip_r + inset,
            cc + chip_r - inset, cc + chip_r - inset],
           outline=(232, 224, 212, 255), width=int(chip_r * 0.10))
cd.ellipse([cc - chip_r + inset * 2, cc - chip_r + inset * 2,
            cc + chip_r - inset * 2, cc + chip_r - inset * 2],
           fill=(255, 252, 246, 255))
chip_shadow = Image.new("RGBA", chip.size, (0, 0, 0, 0))
chip_shadow.paste((20, 10, 20, 100), mask=chip.split()[3])
chip_shadow = chip_shadow.filter(ImageFilter.GaussianBlur(18))
chx, chy = int(S * 0.69), int(S * 0.115)
canvas.alpha_composite(chip_shadow, (chx + 8, chy + 22))
canvas.alpha_composite(chip, (chx, chy))

# whoosh trail: coral motion dashes from the hole toward the chip
tr = ImageDraw.Draw(canvas)
ang = math.atan2(S * 0.19 - S * 0.50, S * 0.745 - S * 0.50)
for i, t in enumerate((0.40, 0.56, 0.72)):
    x = S * 0.50 + (S * 0.745 - S * 0.50) * t
    y = S * 0.50 + (S * 0.19 - S * 0.50) * t
    ln = S * (0.052 - 0.012 * i)
    # dashes run perpendicular offsets so they fan slightly
    off = (i - 1) * S * 0.028
    px_ = x + math.cos(ang + math.pi / 2) * off
    py_ = y + math.sin(ang + math.pi / 2) * off
    tr.line([px_ - math.cos(ang) * ln, py_ - math.sin(ang) * ln,
             px_ + math.cos(ang) * ln, py_ + math.sin(ang) * ln],
            fill=(255, 102, 74, 235), width=int(S * 0.0145))

# --- impact lines (the 치킹! crack) -------------------------------------------
fx = ImageDraw.Draw(canvas)
cxr, cyr = S * 0.115, S * 0.155        # top-left (the chip owns the top-right)
for ang in (2.6, 3.0, 3.45):
    x1 = cxr + math.cos(ang) * S * 0.020
    y1 = cyr + math.sin(ang) * S * 0.020
    x2 = cxr + math.cos(ang) * S * 0.085
    y2 = cyr + math.sin(ang) * S * 0.085
    fx.line([x1, y1, x2, y2], fill=(255, 252, 246, 255), width=int(S * 0.016))
for ang in (2.6, 3.0, 3.45):
    x1 = S * 0.16 + math.cos(ang) * S * 0.018
    y1 = S * 0.84 + math.sin(ang) * S * 0.018
    x2 = S * 0.16 + math.cos(ang) * S * 0.075
    y2 = S * 0.84 + math.sin(ang) * S * 0.075
    fx.line([x1, y1, x2, y2], fill=(255, 252, 246, 235), width=int(S * 0.014))

# --- flatten to RGB (no alpha!) and save --------------------------------------
out = canvas.convert("RGB").resize((1024, 1024), Image.LANCZOS)
out.save("StampCamera/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
out.save("tools/AppIcon-1024.png")
print("saved 1024 icon, alpha-free")
