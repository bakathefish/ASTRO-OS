#!/usr/bin/env python3
"""AstroOS branding asset generator.

Single source of truth: run against the best available logo master and it
emits every branding asset the ISO needs. Rerun whenever the master improves
(e.g. after super-resolution) — all assets regenerate deterministically.

usage: python assetgen.py <logo-master.png> <outdir>
"""

import sys, os, random
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance
import numpy as np

STAR_SEED = 20260825  # reproducible starfield
# The master frame contains a second planet fragment on the far left; keep
# only the ringed planet (fractional crop so it survives upscaled masters).
CONTENT_CROP = (0.24, 0.0, 1.0, 1.0)
KEY_LO, KEY_HI = 26, 60  # smoothstep: <=lo fully transparent, >=hi opaque


def load_keyed(path):
    """Logo with near-black background keyed to alpha, cropped to content."""
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    im = im.crop(
        (
            int(w * CONTENT_CROP[0]),
            int(h * CONTENT_CROP[1]),
            int(w * CONTENT_CROP[2]),
            int(h * CONTENT_CROP[3]),
        )
    )
    a = np.array(im).astype(np.float32)
    maxc = a[..., :3].max(axis=2)
    t = np.clip((maxc - KEY_LO) / (KEY_HI - KEY_LO), 0, 1)
    a[..., 3] = t * t * (3 - 2 * t) * 255  # smoothstep, hard zero below lo
    keyed = Image.fromarray(a.astype(np.uint8))
    bbox = keyed.getbbox()
    return keyed.crop(bbox) if bbox else keyed


def square(im, pad_frac=0.08):
    side = int(max(im.size) * (1 + 2 * pad_frac))
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(im, ((side - im.width) // 2, (side - im.height) // 2), im)
    return sq


def icons(keyed, outdir):
    sq = square(keyed)
    for s in (512, 256, 128, 64, 48, 32, 16):
        d = os.path.join(outdir, "icons", f"{s}x{s}")
        os.makedirs(d, exist_ok=True)
        sq.resize((s, s), Image.LANCZOS).save(os.path.join(d, "astroos-logo.png"))
    sq.resize((256, 256), Image.LANCZOS).save(os.path.join(outdir, "astroos-logo.png"))


def watermark(keyed, outdir):
    """Plymouth spinner watermark: logo on transparency, ~220px wide."""
    w = 220
    h = int(keyed.height * w / keyed.width)
    keyed.resize((w, h), Image.LANCZOS).save(os.path.join(outdir, "watermark.png"))


def ansi_logo(path, outdir, cols=34):
    """Truecolor half-block terminal art for fastfetch (file-raw logo)."""
    im = Image.open(path).convert("RGB")
    rows = max(2, int(im.height / im.width * cols))
    rows += rows % 2
    im = im.resize((cols, rows), Image.LANCZOS)
    px = im.load()
    lines = []
    for y in range(0, rows, 2):
        line = []
        for x in range(cols):
            tr, tg, tb = px[x, y]
            br, bg_, bb = px[x, y + 1]
            line.append(f"\x1b[38;2;{tr};{tg};{tb}m\x1b[48;2;{br};{bg_};{bb}m▀")
        lines.append("".join(line) + "\x1b[0m")
    with open(os.path.join(outdir, "astroos-logo.ansi"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def starfield(w, h):
    rng = random.Random(STAR_SEED)
    im = Image.new("RGB", (w, h))
    # deep-space vertical gradient: near-black up top into dark indigo
    top, bottom = (3, 2, 10), (14, 8, 32)
    grad = np.linspace(0, 1, h)[:, None]
    arr = np.array(top) * (1 - grad[..., None]) + np.array(bottom) * grad[..., None]
    arr = np.repeat(arr, w, axis=1).astype(np.uint8)
    im = Image.fromarray(arr)
    d = ImageDraw.Draw(im)
    for _ in range(w * h // 2500):
        x, y = rng.randrange(w), rng.randrange(h)
        b = rng.randint(70, 255)
        tint = rng.choice(
            [(b, b, b), (b, b, min(255, b + 30)), (min(255, b + 20), b, b)]
        )
        r = rng.choice([0, 0, 0, 1])
        d.ellipse([x - r, y - r, x + r, y + r], fill=tint)
    im = im.filter(ImageFilter.GaussianBlur(0.4))
    # a few brighter stars with glow
    for _ in range(24):
        x, y = rng.randrange(w), rng.randrange(h)
        glow = Image.new("RGB", (32, 32))
        gd = ImageDraw.Draw(glow)
        gd.ellipse([12, 12, 20, 20], fill=(230, 230, 255))
        glow = glow.filter(ImageFilter.GaussianBlur(4))
        im.paste(
            Image.blend(im.crop((x, y, x + 32, y + 32)), glow, 0.6)
            if x + 32 <= w and y + 32 <= h
            else im.crop((x, y, x + 32, y + 32)),
            (x, y),
        )
    return im


def wallpaper(
    keyed, outdir, w=3840, h=2160, name="astroos-wallpaper.png", logo_frac=0.30
):
    bgim = starfield(w, h)
    lw = int(w * logo_frac)
    lh = int(keyed.height * lw / keyed.width)
    logo = keyed.resize((lw, lh), Image.LANCZOS)
    # soft glow behind the logo
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    gl = logo.resize((int(lw * 1.25), int(lh * 1.25)), Image.LANCZOS)
    glow.paste(gl, ((w - gl.width) // 2, (int(h * 0.44) - gl.height // 2)), gl)
    glow = glow.filter(ImageFilter.GaussianBlur(60))
    glow = ImageEnhance.Brightness(glow).enhance(0.7)
    out = bgim.convert("RGBA")
    out.alpha_composite(glow)
    out.alpha_composite(logo, ((w - lw) // 2, int(h * 0.44) - lh // 2))
    out.convert("RGB").save(os.path.join(outdir, name))
    return out


def splashes(keyed, outdir):
    """Bootloader backgrounds: 1920x1080 (grub + syslinux) and 640x480 RGBA."""
    big = wallpaper(keyed, outdir, 1920, 1080, name="splash-1920.png", logo_frac=0.26)
    small = big.resize((640, 480), Image.LANCZOS)  # syslinux vesamenu fallback
    small.save(os.path.join(outdir, "splash-640.png"))


def main():
    master, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    keyed = load_keyed(master)
    icons(keyed, outdir)
    watermark(keyed, outdir)
    ansi_logo(master, outdir)
    wallpaper(keyed, outdir)
    splashes(keyed, outdir)
    print(
        f"assets generated in {outdir} from {master} "
        f"(keyed content {keyed.width}x{keyed.height})"
    )


if __name__ == "__main__":
    main()
