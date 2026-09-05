#!/usr/bin/env python3
"""AstroOS logo, rendered from geometry instead of a screenshot.

The original master (logo-original.png, 168x94) is a low-resolution capture of
a pastel ringed planet; every asset used to be an upscale of it. This module
draws the same planet analytically, so the logo is crisp at any size and its
centre is exactly the planet's centre:

  * sphere: lavender-pink, lit from the upper left, a darker violet blotch on
    the right limb and a soft rim light (the colours of the original);
  * rings: one wide bright cyan band close to the planet and a set of thin
    teal grooves fading outward, in a plane tilted 30 degrees and seen at a
    low inclination, the near arc crossing in front of the planet's lower
    left, the far arc hidden behind it;
  * a faint pink halo around the planet and a cyan halo around the band.

render_logo() returns a straight-alpha RGBA image cropped to the artwork;
write_svg() writes the same construction as a scalable vector (radial
gradients, clipped ellipses) for icon themes and the GNOME login logo.
"""

import math
import numpy as np
from PIL import Image

TILT_DEG = 30.0  # ring major axis, degrees clockwise from +x: upper-left to lower-right
RING_K = 0.36  # ring minor/major axis ratio (viewing inclination)
LIGHT = (-0.55, -0.60, 0.58)

SPHERE_DARK = (0x6E, 0x3F, 0x9C)
SPHERE_MID = (0xC9, 0x9C, 0xDC)
SPHERE_LIGHT = (0xF8, 0xE2, 0xF6)
BLOTCH = (0x86, 0x58, 0xB4)
BAND_IN = (0x4A, 0xC0, 0xDA)
BAND_OUT = (0x96, 0xF2, 0xF7)
LINE_IN = (0x2C, 0xB8, 0xAB)
LINE_OUT = (0x1C, 0x8C, 0x86)
GLOW_PINK = (0xE2, 0x9E, 0xF0)
GLOW_CYAN = (0x62, 0xE2, 0xEC)

BAND_R0, BAND_R1 = 1.18, 1.52
LINES = (
    (1.58, 0.024),
    (1.66, 0.022),
    (1.75, 0.021),
    (1.85, 0.019),
    (1.96, 0.018),
    (2.07, 0.016),
    (2.18, 0.013),
)
RING_OUTER = 2.24


def _smooth(x, e0, e1):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def _c(rgb):
    return np.array(rgb, dtype=np.float32) / 255.0


def _lerp(a, b, t):
    return a * (1.0 - t[..., None]) + b * t[..., None]


def _ring_profile(r):
    """Straight alpha and colour of the ring plane at radius r (planet radii)."""
    band_a = (
        0.95
        * _smooth(r, BAND_R0 - 0.015, BAND_R0 + 0.015)
        * (1.0 - _smooth(r, BAND_R1 - 0.03, BAND_R1 + 0.03))
    )
    band_t = np.clip((r - BAND_R0) / (BAND_R1 - BAND_R0), 0, 1)
    band_col = _lerp(_c(BAND_IN), _c(BAND_OUT), band_t**0.8)
    band_col += 0.12 * np.exp(-(((r - 1.34) / 0.05) ** 2))[..., None]  # bright streak

    haze = (
        0.20
        * _smooth(r, 1.52, 1.57)
        * (1.0 - _smooth(r, RING_OUTER - 0.08, RING_OUTER))
    )
    lines = np.zeros_like(r)
    for p, w in LINES:
        lines += np.exp(-(((r - p) / w) ** 2))
    fade = 1.0 - 0.5 * np.clip((r - 1.52) / (RING_OUTER - 1.52), 0, 1)
    line_a = (
        np.clip(haze + 0.96 * lines, 0, 1)
        * fade
        * (1.0 - _smooth(r, RING_OUTER - 0.03, RING_OUTER + 0.02))
    )
    line_t = np.clip((r - 1.52) / (RING_OUTER - 1.52), 0, 1)
    line_col = _lerp(_c(LINE_IN), _c(LINE_OUT), line_t)

    a = np.clip(band_a + line_a * (1.0 - band_a), 0, 1)
    wb = band_a / np.maximum(a, 1e-6)
    col = _lerp(line_col, band_col, np.clip(wb, 0, 1))
    return a, np.clip(col, 0, 1)


def render_logo(radius=360, margin=1.0):
    """RGBA image of the planet, cropped to the artwork (straight alpha)."""
    R = float(radius)
    half = int(R * (RING_OUTER + margin * 0.25))
    S = 2 * half
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    x = (xx - half + 0.5) / R
    y = (yy - half + 0.5) / R
    px = 1.0 / R

    th = math.radians(TILT_DEG)
    u = x * math.cos(th) + y * math.sin(th)
    v = (-x * math.sin(th) + y * math.cos(th)) / RING_K
    r = np.sqrt(u * u + v * v)
    near = (v > 0).astype(np.float32)
    near = _smooth(v, -0.02, 0.02)  # soft split at the limb

    d2 = x * x + y * y
    d = np.sqrt(d2)
    sphere = 1.0 - _smooth(d, 1.0 - px, 1.0 + px)
    nz = np.sqrt(np.clip(1.0 - d2, 0, 1))
    L = np.array(LIGHT, dtype=np.float32)
    L /= np.linalg.norm(L)
    diff = np.clip(x * L[0] + y * L[1] + nz * L[2], 0, 1)
    t = 0.10 + 0.90 * diff**0.85
    lo = _lerp(_c(SPHERE_DARK), _c(SPHERE_MID), np.clip(t / 0.5, 0, 1))
    hi = _lerp(_c(SPHERE_MID), _c(SPHERE_LIGHT), np.clip((t - 0.5) / 0.5, 0, 1))
    col = np.where((t < 0.5)[..., None], lo, hi)
    blotch = np.exp(-(((x - 0.40) / 0.40) ** 2 + ((y - 0.16) / 0.30) ** 2))
    col = _lerp(col, _c(BLOTCH), 0.45 * blotch)
    lit_side = np.clip(0.5 + 0.5 * (x * L[0] + y * L[1]) / np.maximum(d, 1e-3), 0, 1)
    rim = (1.0 - nz) ** 5 * lit_side
    col = col + rim[..., None] * _c(SPHERE_LIGHT) * 0.40
    shadow = _smooth(r, 0.98, 1.06) * (1.0 - _smooth(r, 1.14, 1.22)) * near
    col = _lerp(col, _c(SPHERE_DARK) * 0.55, 0.50 * shadow)
    col = np.clip(col, 0, 1)

    ring_a, ring_col = _ring_profile(r)
    far_a = ring_a * (1.0 - near) * (1.0 - sphere) * 0.92
    far_col = ring_col * 0.80
    near_a = ring_a * near
    near_col = ring_col

    halo_pink_a = (
        0.28 * np.exp(-(((np.maximum(d - 1.0, 0)) / 0.28) ** 2)) * (1.0 - sphere)
    )
    halo_cyan_a = (
        0.26
        * np.exp(-(((r - 1.35) / 0.30) ** 2))
        * (1.0 - sphere)
        * (0.55 + 0.45 * near)
    )

    out_rgb = np.zeros((S, S, 3), dtype=np.float32)
    out_a = np.zeros((S, S), dtype=np.float32)

    def over(c, a):
        nonlocal out_rgb, out_a
        out_rgb = c * a[..., None] + out_rgb * (1.0 - a[..., None])
        out_a = a + out_a * (1.0 - a)

    over(np.broadcast_to(_c(GLOW_PINK), (S, S, 3)), halo_pink_a)
    over(np.broadcast_to(_c(GLOW_CYAN), (S, S, 3)), halo_cyan_a)
    over(far_col, far_a)
    over(col, sphere)
    over(near_col, near_a)

    rgb = out_rgb / np.maximum(out_a, 1e-6)[..., None]
    rgba = np.concatenate([np.clip(rgb, 0, 1), out_a[..., None]], axis=2)
    im = Image.fromarray((rgba * 255.0 + 0.5).astype(np.uint8))
    alpha = Image.fromarray((np.clip(out_a * 255.0 / 0.02, 0, 255)).astype(np.uint8))
    bbox = alpha.getbbox()
    return im.crop(bbox) if bbox else im


def _hex(rgb):
    return "#%02x%02x%02x" % rgb


def write_svg(path, size=512):
    """Scalable version of the same construction (planet radius = size * 0.215)."""
    R = size * 0.215
    c = size / 2.0
    k = RING_K
    th = TILT_DEG

    def ell(rr, width, color, opacity):
        return (
            f'    <ellipse rx="{rr * R:.2f}" ry="{rr * R * k:.2f}" fill="none" '
            f'stroke="{color}" stroke-width="{width * R:.2f}" opacity="{opacity:.2f}"/>\n'
        )

    rings = ""
    rings += ell(1.35, 0.30, "url(#band)", 0.96)
    rings += ell(1.88, 0.66, _hex(LINE_OUT), 0.16)  # haze between the grooves
    for i, (p, w) in enumerate(LINES):
        tcol = i / (len(LINES) - 1)
        col = tuple(int(a + (b - a) * tcol) for a, b in zip(LINE_IN, LINE_OUT))
        rings += ell(p, w * 2.4, _hex(col), 0.88 - 0.40 * tcol)
    big = size * 2
    svg = f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" width="{size}" height="{size}">
  <title>AstroOS</title>
  <defs>
    <radialGradient id="sphere" cx="0.34" cy="0.30" r="0.85">
      <stop offset="0" stop-color="{_hex(SPHERE_LIGHT)}"/>
      <stop offset="0.42" stop-color="{_hex(SPHERE_MID)}"/>
      <stop offset="0.80" stop-color="#a679c9"/>
      <stop offset="1" stop-color="{_hex(SPHERE_DARK)}"/>
    </radialGradient>
    <radialGradient id="blotch" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="{_hex(BLOTCH)}" stop-opacity="0.55"/>
      <stop offset="1" stop-color="{_hex(BLOTCH)}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="band" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="{_hex(BAND_OUT)}"/>
      <stop offset="0.5" stop-color="{_hex(BAND_IN)}"/>
      <stop offset="1" stop-color="{_hex(BAND_OUT)}"/>
    </linearGradient>
    <radialGradient id="halo" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0.62" stop-color="{_hex(GLOW_PINK)}" stop-opacity="0.18"/>
      <stop offset="1" stop-color="{_hex(GLOW_PINK)}" stop-opacity="0"/>
    </radialGradient>
    <clipPath id="far"><rect x="{-big}" y="{-big}" width="{2 * big}" height="{big}" transform="rotate({th})"/></clipPath>
    <clipPath id="near"><rect x="{-big}" y="0" width="{2 * big}" height="{big}" transform="rotate({th})"/></clipPath>
    <filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="{R * 0.06:.2f}"/></filter>
  </defs>
  <g transform="translate({c:.2f} {c:.2f})">
    <circle r="{R * 1.42:.2f}" fill="url(#halo)"/>
    <g transform="rotate({th})" opacity="0.16" filter="url(#soft)">
      <ellipse rx="{1.35 * R:.2f}" ry="{1.35 * R * k:.2f}" fill="none" stroke="{_hex(GLOW_CYAN)}" stroke-width="{0.46 * R:.2f}"/>
    </g>
    <g clip-path="url(#far)"><g transform="rotate({th})" opacity="0.80">
{rings}    </g></g>
    <circle r="{R:.2f}" fill="url(#sphere)"/>
    <ellipse cx="{0.40 * R:.2f}" cy="{0.16 * R:.2f}" rx="{0.52 * R:.2f}" ry="{0.40 * R:.2f}" fill="url(#blotch)"/>
    <g clip-path="url(#near)"><g transform="rotate({th})">
{rings}    </g></g>
  </g>
</svg>
'''
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(svg)


if __name__ == "__main__":
    import sys

    out = sys.argv[1] if len(sys.argv) > 1 else "logo-preview.png"
    im = render_logo()
    im.save(out)
    write_svg(out.rsplit(".", 1)[0] + ".svg")
    print(out, im.size)
