#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate the MeetingKit app icon (1024x1024, no rounded corners).

Drawn with geometry only (no font rendering) so the result is identical on any
machine regardless of installed fonts. Palette comes from Theme.swift:
background #0B0C0F -> #1B3FA0 -> #2E6BFF, symbol pure white.
"""

import os

from PIL import Image, ImageDraw

SIZE = 1024
SS = 2  # supersampling factor: draw at 2x then downscale for clean AA edges

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(
    PROJECT_ROOT,
    "MeetingKit", "Resources", "Assets.xcassets", "AppIcon.appiconset",
)
OUT_PATH = os.path.join(OUT_DIR, "AppIcon-1024.png")

# Brand colours (0xRRGGBB from Theme.Palette).
C_DARK = (0x0B, 0x0C, 0x0F)
C_MID = (0x1B, 0x3F, 0xA0)
C_BLUE = (0x2E, 0x6B, 0xFF)
WHITE = (0xFF, 0xFF, 0xFF)


def lerp(a, b, t):
    """Linear interpolation between two RGB tuples."""
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def gradient_background(size):
    """Diagonal two-stop gradient, dark top-left -> brand blue bottom-right."""
    img = Image.new("RGB", (size, size), C_DARK)
    px = img.load()
    max_d = (size - 1) * 2.0
    for y in range(size):
        for x in range(size):
            t = (x + y) / max_d          # 0 at top-left, 1 at bottom-right
            if t < 0.5:
                color = lerp(C_DARK, C_MID, t / 0.5)
            else:
                color = lerp(C_MID, C_BLUE, (t - 0.5) / 0.5)
            px[x, y] = color
    return img


def draw_symbol(img):
    """White screen-share glyph: outlined screen + shared frame + participant dot."""
    draw = ImageDraw.Draw(img)
    s = img.size[0]
    scale = s / SIZE  # keep proportions identical to the 1024 spec

    # --- 520x360 outlined rounded rect, lineWidth 34 (screen) ---
    screen_w, screen_h = 520 * scale, 360 * scale
    line_w = 34 * scale
    screen_left = (s - screen_w) / 2.0
    screen_top = (s - screen_h) / 2.0 - 40 * scale
    screen_right = screen_left + screen_w
    screen_bottom = screen_top + screen_h
    screen_radius = 60 * scale

    draw.rounded_rectangle(
        [screen_left, screen_top, screen_right, screen_bottom],
        radius=screen_radius,
        outline=WHITE,
        width=int(round(line_w)),
    )

    # --- 120x84 filled rounded rect (the shared content) ---
    frame_w, frame_h = 120 * scale, 84 * scale
    frame_left = (s - frame_w) / 2.0
    frame_top = screen_top + (screen_h - frame_h) / 2.0
    draw.rounded_rectangle(
        [frame_left, frame_top, frame_left + frame_w, frame_top + frame_h],
        radius=18 * scale,
        fill=WHITE,
    )

    # --- participant avatar: filled circle on the bottom-right rim, ---
    # --- separated from the outline by a dark ring (24px).              ---
    dot_r = 96 * scale
    dot_cx = screen_right - 10 * scale
    dot_cy = screen_bottom - 10 * scale

    ring_r = dot_r + 24 * scale
    draw.ellipse(
        [dot_cx - ring_r, dot_cy - ring_r, dot_cx + ring_r, dot_cy + ring_r],
        fill=C_DARK,
    )
    draw.ellipse(
        [dot_cx - dot_r, dot_cy - dot_r, dot_cx + dot_r, dot_cy + dot_r],
        fill=WHITE,
    )
    return img


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    canvas = gradient_background(SIZE * SS)
    canvas = draw_symbol(canvas)
    canvas = canvas.resize((SIZE, SIZE), Image.LANCZOS)

    # Flatten to RGB with no alpha: App Store icons must not carry transparency.
    canvas = canvas.convert("RGB")
    canvas.save(OUT_PATH, format="PNG", optimize=True)

    with Image.open(OUT_PATH) as check:
        print("path   :", OUT_PATH)
        print("size   :", check.size)
        print("mode   :", check.mode)
        print("bytes  :", os.path.getsize(OUT_PATH))


if __name__ == "__main__":
    main()
