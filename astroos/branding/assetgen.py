#!/usr/bin/env python3
"""AstroOS branding asset generator.

Single source of truth for every branding image: the planet is drawn by
logo.py (procedural, any size, exactly centred), the type is the vendored
Space Grotesk and JetBrains Mono faces in fonts/ (OFL), and the starfield has
a fixed seed, so a rerun on any machine regenerates the same assets. The
committed PNGs in out/ are what the ISO build and the packages consume.

usage: python assetgen.py <outdir>

Outputs (outdir):
  logo-master.png, astroos-logo.svg                   hi-res render + vector
  icons/<s>x<s>/astroos-logo.png, astroos-logo.png    hicolor icons + pixmap
  refind/os_astroos.png                               rEFInd OS icon (128)
  watermark.png                                       plymouth spinner watermark
  astroos-logo.ansi                                   fastfetch truecolor logo
  astroos-wallpaper.png, wallpaper-preview.png        3840x2160 + KPackage screenshot
  splash-1920.png, splash-640.png                     GRUB/syslinux/Limine backgrounds
  calamares/{logo,icon,welcome,slide1..3}.png         installer branding component
  calamares/bootloaders/{grub,limine,systemd-boot,refind}.png   installer previews
  calamares/desktops/<id>.png                         installer desktop cards
"""

import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont

from logo import render_logo, write_svg

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_DIR = os.path.join(HERE, "fonts")
STAR_SEED = 20260825  # reproducible starfield

# palette (shared with logo.py's planet)
SPACE_TOP = (3, 2, 10)
SPACE_BOTTOM = (14, 8, 32)
SPACE_WINDOW = (
    27,
    22,
    48,
)  # palette "window": the flat surface the installer images sit on
NEBULA_LAVENDER = (108, 79, 176)
NEBULA_TEAL = (31, 127, 138)
TEXT_MAIN = (232, 230, 245)
TEXT_SUB = (200, 196, 222)
TEXT_DIM = (150, 146, 178)
ACCENT_CYAN = (143, 240, 245)
ACCENT_PINK = (226, 158, 240)

FONT_FALLBACKS = (
    "C:/Windows/Fonts/segoeuib.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/noto/NotoSans-Bold.ttf",
)


def _font(size, weight=700, mono=False):
    name = ("JetBrainsMono" if mono else "SpaceGrotesk") + f"-{weight}.ttf"
    p = os.path.join(FONT_DIR, name)
    if os.path.exists(p):
        return ImageFont.truetype(p, size)
    for q in FONT_FALLBACKS:
        if os.path.exists(q):
            return ImageFont.truetype(q, size)
    return ImageFont.load_default(size=size)


def starfield(w, h):
    """Deep-space gradient with a seeded star scatter (a few bright ones glow)."""
    rng = random.Random(STAR_SEED)
    grad = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
    arr = np.array(SPACE_TOP) * (1 - grad) + np.array(SPACE_BOTTOM) * grad
    im = Image.fromarray(np.repeat(arr, w, axis=1).astype(np.uint8))
    d = ImageDraw.Draw(im)
    for _ in range(w * h // 2500):
        x, y = rng.randrange(w), rng.randrange(h)
        b = rng.randint(70, 255)
        tint = rng.choice(
            ((b, b, b), (b, b, min(255, b + 20)), (min(255, b + 10), b, b))
        )
        d.point((x, y), fill=tint)
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    g = ImageDraw.Draw(glow)
    for _ in range(max(6, w * h // 90000)):
        x, y = rng.randrange(w), rng.randrange(h)
        r = rng.randint(1, max(2, w // 700))
        g.ellipse((x - r, y - r, x + r, y + r), fill=(235, 232, 250))
    glow = glow.filter(ImageFilter.GaussianBlur(max(1, w // 900)))
    return Image.fromarray(
        np.clip(
            np.array(im, dtype=np.int16) + np.array(glow, dtype=np.int16) // 2, 0, 255
        ).astype(np.uint8)
    )


def nebula(im, blobs, strength=1.0):
    """Soft colour clouds (ellipses blurred hard) composited over im in place."""
    w, h = im.size
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for fx, fy, fw, fh, col, a in blobs:
        cx, cy, rw, rh = fx * w, fy * h, fw * w / 2, fh * h / 2
        d.ellipse(
            (cx - rw, cy - rh, cx + rw, cy + rh), fill=col + (int(255 * a * strength),)
        )
    layer = layer.filter(ImageFilter.GaussianBlur(w // 9))
    im.alpha_composite(layer)
    return im


def place_logo(canvas, logo, cx, cy, width, glow=0.7):
    """Paste the planet centred at (cx, cy) at the given width with a soft glow."""
    lw = int(width)
    lh = int(logo.height * lw / logo.width)
    lg = logo.resize((lw, lh), Image.LANCZOS)
    if glow > 0:
        gl = lg.resize((int(lw * 1.25), int(lh * 1.25)), Image.LANCZOS)
        layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        layer.paste(gl, (int(cx - gl.width / 2), int(cy - gl.height / 2)), gl)
        layer = layer.filter(ImageFilter.GaussianBlur(max(12, lw // 8)))
        layer = ImageEnhance.Brightness(layer).enhance(glow)
        canvas.alpha_composite(layer)
    canvas.alpha_composite(lg, (int(cx - lw / 2), int(cy - lh / 2)))
    return canvas


def wordmark(draw, xy, px, anchor="la", main=TEXT_MAIN, accent=ACCENT_CYAN, weight=700):
    """'AstroOS' with the OS in the accent colour; returns the total width."""
    f = _font(px, weight)
    a = "Astro"
    wa = draw.textlength(a, font=f)
    wo = draw.textlength("OS", font=f)
    x, y = xy
    if anchor[0] == "m":
        x = x - (wa + wo) / 2
        anchor = "l" + anchor[1]
    draw.text((x, y), a, font=f, fill=main, anchor=anchor)
    draw.text((x + wa, y), "OS", font=f, fill=accent, anchor=anchor)
    return wa + wo


def square(im, pad_frac=0.08):
    side = int(max(im.size) * (1 + 2 * pad_frac))
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(im, ((side - im.width) // 2, (side - im.height) // 2), im)
    return sq


# --- assets ---------------------------------------------------------------


def icons(logo, outdir):
    sq = square(logo)
    for s in (512, 256, 128, 64, 48, 32, 16):
        d = os.path.join(outdir, "icons", f"{s}x{s}")
        os.makedirs(d, exist_ok=True)
        sq.resize((s, s), Image.LANCZOS).save(os.path.join(d, "astroos-logo.png"))
    sq.resize((256, 256), Image.LANCZOS).save(os.path.join(outdir, "astroos-logo.png"))
    d = os.path.join(outdir, "refind")
    os.makedirs(d, exist_ok=True)
    sq.resize((128, 128), Image.LANCZOS).save(os.path.join(d, "os_astroos.png"))


def watermark(logo, outdir):
    """Plymouth spinner watermark: logo on transparency, ~220px wide."""
    w = 220
    h = int(logo.height * w / logo.width)
    logo.resize((w, h), Image.LANCZOS).save(os.path.join(outdir, "watermark.png"))


def ansi_logo(logo, outdir, cols=44):
    """Truecolor half-block terminal art for fastfetch (file-raw logo).

    Transparent cells stay unpainted (a plain space), so the logo sits on the
    terminal's own background instead of a black box.

    44 columns (44x40 half-block pixels) rather than the 32 the first cut
    used: at 32 the ring was three pixels thick and the planet a blob, the one
    thing in a Konsole screenshot that read as amateur (2026-09-06). The width
    budget is the fastfetch config's: 44 columns plus 3 of padding leaves an
    info line up to about 62 characters on Konsole's default 110-column
    window before it wraps under the logo.
    """
    rows = max(2, int(logo.height / logo.width * cols * 1.0))
    rows += rows % 2
    im = logo.resize((cols, rows), Image.LANCZOS)
    px = im.load()
    lines = []
    for y in range(0, rows, 2):
        line = []
        for x in range(cols):
            tr, tg, tb, ta = px[x, y]
            br, bg_, bb, ba = px[x, y + 1]
            top, bot = ta > 64, ba > 64
            if top and bot:
                line.append(
                    f"\x1b[38;2;{tr};{tg};{tb}m\x1b[48;2;{br};{bg_};{bb}m▀\x1b[0m"
                )
            elif top:
                line.append(f"\x1b[38;2;{tr};{tg};{tb}m▀\x1b[0m")
            elif bot:
                line.append(f"\x1b[38;2;{br};{bg_};{bb}m▄\x1b[0m")
            else:
                line.append(" ")
        lines.append("".join(line).rstrip())
    with open(
        os.path.join(outdir, "astroos-logo.ansi"), "w", encoding="utf-8", newline="\n"
    ) as f:
        f.write("\n".join(lines) + "\n")


def wallpaper(
    logo,
    outdir,
    w=3840,
    h=2160,
    name="astroos-wallpaper.png",
    logo_frac=0.30,
    cx_frac=0.50,
    cy_frac=0.46,
):
    im = starfield(w, h).convert("RGBA")
    nebula(
        im,
        [
            (0.22, 0.30, 0.55, 0.45, NEBULA_LAVENDER, 0.16),
            (0.78, 0.72, 0.50, 0.40, NEBULA_TEAL, 0.10),
        ],
    )
    place_logo(im, logo, w * cx_frac, h * cy_frac, w * logo_frac, glow=0.75)
    im.convert("RGB").save(os.path.join(outdir, name))
    return im


def login_background(logo, outdir):
    """Greeter background. Both greeters centre the clock, the avatar and the
    password field on the upper middle of the screen, so the planet sits low
    and right of that column instead of directly behind the avatar, where it
    showed only as a coloured smudge (seen in the 2026-09-06 install run)."""
    return wallpaper(
        logo,
        outdir,
        name="login-background.png",
        logo_frac=0.22,
        cx_frac=0.73,
        cy_frac=0.63,
    )


def wallpaper_preview(outdir):
    im = Image.open(os.path.join(outdir, "astroos-wallpaper.png"))
    im.resize((400, 225), Image.LANCZOS).save(
        os.path.join(outdir, "wallpaper-preview.png")
    )


def boot_scene(logo, w, h):
    """Bootloader background: the menu is drawn in the centre by GRUB and Limine,
    so the planet and the wordmark sit in the upper left and the centre stays clear."""
    im = starfield(w, h).convert("RGBA")
    nebula(
        im,
        [
            (0.18, 0.22, 0.50, 0.50, NEBULA_LAVENDER, 0.18),
            (0.85, 0.80, 0.45, 0.45, NEBULA_TEAL, 0.12),
        ],
    )
    lw = w * 0.13
    place_logo(im, logo, w * 0.11, h * 0.16, lw, glow=0.6)
    d = ImageDraw.Draw(im)
    wordmark(d, (w * 0.185, h * 0.16), int(h * 0.075), anchor="lm")
    return im


def splashes(logo, outdir):
    """GRUB + syslinux (live ISO) and Limine (installed) backgrounds."""
    big = boot_scene(logo, 1920, 1080)
    big.convert("RGB").save(os.path.join(outdir, "splash-1920.png"))
    big.resize((640, 480), Image.LANCZOS).convert("RGB").save(
        os.path.join(outdir, "splash-640.png")
    )
    return big


def scene(logo, w, h, logo_frac, logo_cy, title, subtitle, title_px, sub_px):
    """Starfield + glowing planet centred at logo_cy (fraction of h) + captions."""
    im = starfield(w, h).convert("RGBA")
    nebula(
        im,
        [
            (0.25, 0.35, 0.55, 0.5, NEBULA_LAVENDER, 0.14),
            (0.78, 0.70, 0.45, 0.4, NEBULA_TEAL, 0.09),
        ],
    )
    place_logo(im, logo, w / 2, h * logo_cy, w * logo_frac, glow=0.75)
    d = ImageDraw.Draw(im)
    lh = int(logo.height * (w * logo_frac) / logo.width)
    y = h * logo_cy + lh / 2 + h * 0.06
    if title == "AstroOS":
        wordmark(d, (w / 2, y), title_px, anchor="ma")
    elif title:
        d.text((w / 2, y), title, font=_font(title_px), fill=TEXT_MAIN, anchor="ma")
    if subtitle:
        d.text(
            (w / 2, y + title_px * 1.45),
            subtitle,
            font=_font(sub_px, 500),
            fill=TEXT_SUB,
            anchor="ma",
        )
    return im.convert("RGB")


SLIDES = (
    ("AstroOS", "A rolling research workstation on Arch Linux"),
    (
        "Astronomy stack included",
        "Stellarium, KStars, AstrOmatic, Siril, DS9, TOPCAT, Aladin, sunpy, healpy",
    ),
    (
        "Research and security tooling",
        "Jupyter, Julia, R, ROOT, ParaView, TeX Live; nmap, Wireshark, BlackArch on demand",
    ),
)


def plain_scene(
    logo, w, h, logo_frac, logo_cy, title=None, subtitle=None, title_px=0, sub_px=0
):
    """A flat brand surface (the window colour), the planet as drawn, and at
    most two lines of text. The installer's images since 2026-09-06: the
    starfield, nebula and glow version of the welcome page read as overdone
    next to the plain pages around it (owner's note), and CachyOS's own
    installer, the shape this one follows, shows a logo on a flat surface."""
    im = Image.new("RGBA", (w, h), SPACE_WINDOW + (255,))
    lw = int(w * logo_frac)
    lh = int(logo.height * lw / logo.width)
    im.alpha_composite(
        logo.resize((lw, lh), Image.LANCZOS),
        (int(w / 2 - lw / 2), int(h * logo_cy - lh / 2)),
    )
    if title or subtitle:
        d = ImageDraw.Draw(im)
        y = h * logo_cy + lh / 2 + h * 0.06
        if title:
            d.text((w / 2, y), title, font=_font(title_px), fill=TEXT_MAIN, anchor="ma")
        if subtitle:
            d.text(
                (w / 2, y + title_px * 1.45),
                subtitle,
                font=_font(sub_px, 500),
                fill=TEXT_SUB,
                anchor="ma",
            )
    return im


def calamares(logo, outdir):
    """Installer branding component images (sizes match the upstream component)."""
    d = os.path.join(outdir, "calamares")
    os.makedirs(d, exist_ok=True)
    sq = square(logo)
    sq.resize((64, 64), Image.LANCZOS).save(os.path.join(d, "logo.png"))
    sq.resize((128, 128), Image.LANCZOS).save(os.path.join(d, "icon.png"))
    # the welcome page: the planet on the flat surface, nothing else; the
    # page's own heading already says whose installer it is
    plain_scene(logo, 900, 516, 0.30, 0.50).save(os.path.join(d, "welcome.png"))
    for i, (title, sub) in enumerate(SLIDES, start=1):
        plain_scene(logo, 1920, 1080, 0.22, 0.40, title, sub, 84, 36).save(
            os.path.join(d, f"slide{i}.png")
        )


# --- installer previews (packagechooser screenshots) ----------------------

GRUB_ENTRIES = (
    "AstroOS Linux",
    "Advanced options for AstroOS Linux",
    "UEFI Firmware Settings",
    "AstroOS Linux snapshots",
)
# Entry labels in these previews are the generic ones ("Linux", "Linux LTS"):
# a real menu prints the kernel package's own version string, which is not
# AstroOS's to rename, and these images are the page's illustration of the
# menu's shape and branding, not a screenshot of one machine.
KERNEL_MAIN, KERNEL_LTS = "Linux", "Linux LTS"


def preview_grub(logo, outdir, w=1600, h=1000):
    """GRUB as AstroOS configures it: gfxterm menu over the AstroOS background."""
    im = boot_scene(logo, w, h)
    d = ImageDraw.Draw(im)
    mono = _font(int(h * 0.026), 400, mono=True)
    d.text(
        (w / 2, h * 0.055),
        "GNU GRUB  version 2.14",
        font=mono,
        fill=(220, 220, 220),
        anchor="mm",
    )
    x0, y0, x1, y1 = w * 0.09, h * 0.34, w * 0.91, h * 0.62
    d.rectangle((x0, y0, x1, y1), outline=(200, 200, 200), width=2)
    d.rectangle((x0 + 5, y0 + 5, x1 - 5, y1 - 5), outline=(200, 200, 200), width=1)
    line = h * 0.05
    for i, e in enumerate(GRUB_ENTRIES):
        y = y0 + line * (0.9 + i)
        if i == 0:
            d.rectangle(
                (x0 + 14, y - line * 0.42, x1 - 14, y + line * 0.42),
                fill=(215, 215, 215),
            )
            d.text((x0 + 34, y), "*" + e, font=mono, fill=(20, 20, 30), anchor="lm")
        else:
            d.text((x0 + 34, y), " " + e, font=mono, fill=(225, 225, 225), anchor="lm")
    help_font = _font(int(h * 0.021), 400, mono=True)
    for i, t in enumerate(
        (
            "Use the ▲ and ▼ keys to select which entry is highlighted.",
            "Press enter to boot the selected OS, `e' to edit the commands before booting or `c' for a command-line.",
            "The highlighted entry will be executed automatically in 5s.",
        )
    ):
        d.text(
            (w / 2, h * (0.76 + i * 0.04)),
            t,
            font=help_font,
            fill=(200, 200, 200),
            anchor="mm",
        )
    im.convert("RGB").save(os.path.join(outdir, "grub.png"))


def preview_limine(logo, outdir, w=1600, h=1000):
    """Limine as AstroOS configures it: its text menu over the AstroOS background."""
    im = boot_scene(logo, w, h)
    d = ImageDraw.Draw(im)
    mono = _font(int(h * 0.031), 400, mono=True)
    green, white = (150, 216, 150), (225, 225, 235)

    def hint(x, y, key, label):
        d.text((x, y), key, font=mono, fill=green, anchor="lm")
        d.text(
            (x + d.textlength(key + " ", font=mono), y),
            label,
            font=mono,
            fill=white,
            anchor="lm",
        )

    y = h * 0.30
    x = w * 0.08
    for key, label in (("ARROWS", "Select"), ("ENTER", "Boot"), ("E", "Edit")):
        hint(x, y, key, label)
        x += d.textlength(key + " " + label, font=mono) + w * 0.03
    right = (("S", "Firmware Setup"), ("B", "Blank Entry"))
    total = sum(d.textlength(k + " " + l, font=mono) for k, l in right) + w * 0.03 * (
        len(right) - 1
    )
    x = w * 0.92 - total
    for key, label in right:
        hint(x, y, key, label)
        x += d.textlength(key + " " + label, font=mono) + w * 0.03
    cx, cy = w * 0.39, h * 0.49
    lh = h * 0.038
    d.text((cx, cy), "[-] AstroOS", font=mono, fill=white, anchor="lm")
    sel = KERNEL_MAIN
    tw = d.textlength(sel, font=mono)
    d.text((cx + w * 0.012, cy + lh), "├──▶", font=mono, fill=white, anchor="lm")
    ax = cx + w * 0.012 + d.textlength("├──▶ ", font=mono)
    d.rectangle(
        (ax - 6, cy + lh - lh * 0.45, ax + tw + 6, cy + lh + lh * 0.45),
        fill=(214, 210, 236),
    )
    d.text((ax, cy + lh), sel, font=mono, fill=(22, 18, 40), anchor="lm")
    d.text(
        (cx + w * 0.012, cy + 2 * lh),
        "└──▶ " + KERNEL_LTS,
        font=mono,
        fill=white,
        anchor="lm",
    )
    d.text(
        (cx + w * 0.038, cy + 3 * lh),
        "EFI fallback",
        font=mono,
        fill=white,
        anchor="lm",
    )
    im.convert("RGB").save(os.path.join(outdir, "limine.png"))


def preview_systemd_boot(outdir, w=1600, h=1000):
    """systemd-boot has no theme: a plain text menu, titled per kernel."""
    im = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(im)
    mono = _font(int(h * 0.028), 400, mono=True)
    entries = (
        "AstroOS " + KERNEL_MAIN,
        "AstroOS " + KERNEL_LTS,
        "Reboot Into Firmware Interface",
    )
    lh = h * 0.045
    y0 = h * 0.46
    widest = max(d.textlength(e, font=mono) for e in entries)
    for i, e in enumerate(entries):
        y = y0 + i * lh
        if i == 0:
            d.rectangle(
                (
                    w / 2 - widest / 2 - 40,
                    y - lh * 0.45,
                    w / 2 + widest / 2 + 40,
                    y + lh * 0.45,
                ),
                fill=(170, 170, 170),
            )
            d.text((w / 2, y), e, font=mono, fill=(0, 0, 0), anchor="mm")
        else:
            d.text((w / 2, y), e, font=mono, fill=(200, 200, 200), anchor="mm")
    ly = y0 + len(entries) * lh
    d.line(
        (w / 2 - widest / 2 - 60, ly, w / 2 + widest / 2 + 60, ly),
        fill=(200, 200, 200),
        width=2,
    )
    d.text(
        (w / 2, ly + lh * 0.9),
        "Boot in 5 s.",
        font=mono,
        fill=(200, 200, 200),
        anchor="mm",
    )
    im.save(os.path.join(outdir, "systemd-boot.png"))


def preview_refind(logo, outdir):
    """rEFInd remix: the upstream screenshot (rEFInd's own artwork) with the
    generic Tux tile replaced by the AstroOS OS icon that astroos-branding
    ships as /usr/share/refind/icons/os_astroos.png, and the volume size of
    the AstroOS ESP."""
    base = Image.open(os.path.join(HERE, "src", "refind-base.png")).convert("RGBA")
    w, h = base.size
    bg = base.getpixel((40, 40))[:3]
    d = ImageDraw.Draw(base)
    # OS tile: rounded grey square where rEFInd draws the selected loader
    tx0, ty0, tx1, ty1 = 648, 432, 832, 616
    d.rounded_rectangle((tx0 - 4, ty0 - 4, tx1 + 4, ty1 + 4), radius=18, fill=bg)
    d.rounded_rectangle(
        (tx0, ty0, tx1, ty1),
        radius=16,
        fill=(125, 124, 124),
        outline=(150, 150, 150),
        width=2,
    )
    icon = square(logo, 0.02).resize((172, 172), Image.LANCZOS)
    base.alpha_composite(
        icon, (tx0 + (tx1 - tx0 - 172) // 2, ty0 + (ty1 - ty0 - 172) // 2)
    )
    # status lines under the icons (the ESP is 4 GiB on AstroOS)
    d.rectangle((0, 738, w, 795), fill=bg)
    mono = _font(23, 400, mono=True)
    d.text(
        (w / 2, 755),
        "Boot AstroOS from 4 GiB FAT volume",
        font=mono,
        fill=(48, 48, 48),
        anchor="mm",
    )
    d.text(
        (w / 2, 779),
        "Automatic boot in 5 seconds",
        font=mono,
        fill=(48, 48, 48),
        anchor="mm",
    )
    base.convert("RGB").save(os.path.join(outdir, "refind.png"))


DESKTOPS = (
    ("plasma", "Plasma Desktop", "KDE Plasma 6, the AstroOS default"),
    ("gnome", "GNOME", "GNOME desktop"),
    ("cosmic", "COSMIC", "System76's COSMIC desktop"),
    ("niri", "Niri", "scrollable-tiling Wayland compositor"),
    ("cinnamon", "Cinnamon", "Cinnamon desktop"),
    ("budgie", "Budgie", "Budgie desktop"),
    ("mate", "MATE", "MATE desktop"),
    ("xfce", "Xfce", "Xfce desktop"),
    ("lxqt", "LXQt", "LXQt desktop"),
    ("lxde", "LXDE", "LXDE desktop"),
    ("hyprland", "Hyprland", "dynamic tiling Wayland compositor"),
    ("mango", "MangoWM", "Wayland compositor with the Noctalia shell"),
    ("sway", "Sway", "i3-compatible Wayland compositor"),
    ("wayfire", "Wayfire", "3D Wayland compositor"),
    ("i3", "i3", "i3 window manager"),
    ("qtile", "Qtile", "Qtile window manager"),
    ("bspwm", "bspwm", "bspwm window manager"),
    ("openbox", "Openbox", "Openbox window manager"),
)


def desktop_cards(logo, outdir, w=1280, h=720):
    """One card per desktop choice: the planet on the right, the desktop's name
    on the left. plasma.png is replaced by a real screenshot when one exists
    (src/plasma-screenshot.png)."""
    d_out = os.path.join(outdir, "calamares", "desktops")
    os.makedirs(d_out, exist_ok=True)
    for key, name, desc in DESKTOPS:
        shot = os.path.join(HERE, "src", f"{key}-screenshot.png")
        if os.path.exists(shot):
            Image.open(shot).convert("RGB").save(os.path.join(d_out, f"{key}.png"))
            continue
        im = starfield(w, h).convert("RGBA")
        nebula(
            im,
            [
                (0.75, 0.45, 0.6, 0.7, NEBULA_LAVENDER, 0.16),
                (0.15, 0.85, 0.5, 0.5, NEBULA_TEAL, 0.10),
            ],
        )
        place_logo(im, logo, w * 0.72, h * 0.50, w * 0.42, glow=0.75)
        d = ImageDraw.Draw(im)
        eyebrow = _font(int(h * 0.036), 500)
        d.text(
            (w * 0.08, h * 0.36),
            "A S T R O O S",
            font=eyebrow,
            fill=ACCENT_CYAN,
            anchor="ls",
        )
        title_px = int(h * 0.15) if len(name) <= 8 else int(h * 0.11)
        d.text(
            (w * 0.08, h * 0.52),
            name,
            font=_font(title_px),
            fill=TEXT_MAIN,
            anchor="ls",
        )
        d.line(
            (w * 0.08, h * 0.575, w * 0.08 + w * 0.06, h * 0.575),
            fill=ACCENT_PINK,
            width=4,
        )
        d.text(
            (w * 0.08, h * 0.66),
            desc,
            font=_font(int(h * 0.040), 500),
            fill=TEXT_SUB,
            anchor="ls",
        )
        im.convert("RGB").save(os.path.join(d_out, f"{key}.png"))


def previews(logo, outdir):
    d = os.path.join(outdir, "calamares", "bootloaders")
    os.makedirs(d, exist_ok=True)
    preview_grub(logo, d)
    preview_limine(logo, d)
    preview_systemd_boot(d)
    preview_refind(logo, d)
    desktop_cards(logo, outdir)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: assetgen.py <outdir>")
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    logo = render_logo()
    logo.save(os.path.join(outdir, "logo-master.png"))
    write_svg(os.path.join(outdir, "astroos-logo.svg"))
    icons(logo, outdir)
    watermark(logo, outdir)
    ansi_logo(logo, outdir)
    wallpaper(logo, outdir)
    wallpaper_preview(outdir)
    login_background(logo, outdir)
    splashes(logo, outdir)
    calamares(logo, outdir)
    previews(logo, outdir)
    print(f"assets generated in {outdir} (procedural logo {logo.width}x{logo.height})")


if __name__ == "__main__":
    main()
