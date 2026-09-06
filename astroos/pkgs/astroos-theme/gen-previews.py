#!/usr/bin/env python3
"""Draw the two 400x225 previews KDE shows for the AstroOS global theme.

    python3 astroos/pkgs/astroos-theme/gen-previews.py

Writes, under this package's files/ tree so the PNGs are committed like any
other payload:

    .../org.astroos.desktop/contents/previews/preview.png   the theme card
    .../org.astroos.desktop/contents/previews/splash.png    the splash card

Both are the space gradient the wallpaper and the splash use, so the card in
System Settings shows the same surface the theme actually paints. Colours come
from astroos/branding/palette.py by role; nothing here invents one. The images
are drawn at 4x and downsampled, which is the only place a colour outside the
palette appears: the anti-aliased edge pixels between two palette colours, the
same blend the gradient itself is made of.
"""

import os
import sys

from PIL import Image, ImageDraw

# palette.py sits two directories up, in astroos/branding
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "branding"))
from palette import rgb  # noqa: E402

OUT = os.path.join(
    HERE,
    "files",
    "usr",
    "share",
    "plasma",
    "look-and-feel",
    "org.astroos.desktop",
    "contents",
    "previews",
)

W, H = 400, 225
SS = 4  # supersampling factor: rounded corners and a 2 px line need it


def gradient(w, h):
    """The deep-space gradient, space_top at the top, drawn one row at a time."""
    top, bottom = rgb("space_top"), rgb("space_bottom")
    img = Image.new("RGB", (w, h))
    draw = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        draw.line(
            [(0, y), (w, y)],
            fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)),
        )
    return img


def preview():
    """The theme card: the gradient with three swatches in the bottom left.

    window, lavender, cyan: the surface, the accent and the link colour, the
    three a viewer needs to tell this theme from another at card size. The
    window swatch is nearly the gradient it sits on, so every swatch takes a
    line-coloured border and the dark one still reads as a swatch.
    """
    img = gradient(W * SS, H * SS)
    draw = ImageDraw.Draw(img)
    size, gap, radius = 30 * SS, 12 * SS, 7 * SS
    x, y = 22 * SS, H * SS - 22 * SS - size
    for role in ("window", "lavender", "cyan"):
        draw.rounded_rectangle(
            [x, y, x + size, y + size],
            radius=radius,
            fill=rgb(role),
            outline=rgb("line"),
            width=SS,
        )
        x += size + gap
    return img.resize((W, H), Image.LANCZOS)


def splash():
    """The splash card: the gradient with the progress line, centred.

    The same two things Splash.qml draws at boot, minus the logo, which is
    unreadable at 400x225 and belongs to astroos-branding rather than here.
    """
    img = gradient(W * SS, H * SS)
    draw = ImageDraw.Draw(img)
    length, thickness = 120 * SS, 2 * SS
    x0 = (W * SS - length) // 2
    y0 = (H * SS - thickness) // 2
    draw.rectangle([x0, y0, x0 + length, y0 + thickness], fill=rgb("lavender"))
    return img.resize((W, H), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, img in (("preview.png", preview()), ("splash.png", splash())):
        path = os.path.join(OUT, name)
        img.save(path, "PNG", optimize=True)
        print("wrote %s (%dx%d)" % (path, img.width, img.height))


if __name__ == "__main__":
    main()
