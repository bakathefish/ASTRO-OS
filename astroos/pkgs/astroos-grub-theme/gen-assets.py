#!/usr/bin/env python3
"""Draw the two image assets the AstroOS GRUB theme needs.

usage: python3 gen-assets.py          (writes into files/usr/share/grub/themes/astroos)

Run once on a workstation with Pillow; the PNGs are committed, because the ISO
and package builds fetch nothing and install no Python. Colours come from
astroos/branding/palette.py, the same table the Plymouth theme, the Plasma
scheme and the installer read, so the boot menu is the first screen of one
colour scheme rather than a lookalike.

Outputs:
  background.png      1920x1080 desktop-image: the space gradient plus the
                      seeded star scatter assetgen.py's wallpaper uses
  select_*.png        the nine slices GRUB composes into the selected-item
                      highlight: a lavender rounded bar
  item_*.png          the same nine sizes, fully transparent

Why item_*.png exists at all: GRUB draws a menu item's text at
item_top + top_pad of that item's own box (grub-core/gfxmenu/gui_list.c,
draw_menu), so a selected item whose box has a 6 px top pad and unselected
items with no box at all would sit 6 px apart vertically and the text would
hop as the cursor moves. An empty box of the same geometry for the unselected
items keeps every line on the same baseline.

Geometry, from the same file: the highlight is drawn as content(item_height)
plus the box pads, and the pads are the slice sizes (widget-box.c: top pad is
the tallest of n/nw/ne, left pad the widest of w/nw/sw). With item_height 36
and item_spacing 6 the vertical pad has to be 6 for the highlight to end
exactly where the next line's text begins, so the corner tiles are 12 wide by
6 tall: 12 px of horizontal inset before the text, 6 px above and below, and a
6 px radius that fits inside the corner tile in both directions.
"""

import os
import random
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..", "..", "branding")))
import palette as P  # noqa: E402

OUT = os.path.join(HERE, "files", "usr", "share", "grub", "themes", "astroos")
STAR_SEED = 20260825  # assetgen.py's seed: the same sky behind menu and desktop
BG_W, BG_H = 1920, 1080
SW, SH, RADIUS = 12, 6, 6  # slice width, slice height, corner radius
SS = 4  # supersampling factor: Pillow's rounded_rectangle has no antialiasing


def starfield(w, h):
    """Deep-space gradient with a seeded star scatter, Pillow only.

    assetgen.py's version adds a numpy glow pass; this one keeps the idea (the
    same seed, the same density, stars as dimmed text-white) in a form the
    theme needs no extra dependency for.
    """
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    top, bottom = P.rgb("space_top"), P.rgb("space_bottom")
    for y in range(h):
        t = y / (h - 1)
        d.line(
            [(0, y), (w, y)],
            fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)),
        )
    rng = random.Random(STAR_SEED)
    star = P.rgb("text")
    for _ in range(w * h // 2500):
        x, y, b = rng.randrange(w), rng.randrange(h), rng.uniform(0.28, 1.0)
        d.point((x, y), fill=tuple(round(c * b) for c in star))
    return im


def slices(prefix, fill):
    """The nine box slices GRUB stretches into a rounded bar.

    Corners carry the arc; the four edge slices are 1 px in the direction GRUB
    stretches (the convention its own starfield theme uses) so nothing is
    resampled along the bar.
    """
    box = Image.new("RGBA", (2 * SW * SS, 2 * SH * SS), (0, 0, 0, 0))
    ImageDraw.Draw(box).rounded_rectangle(
        (0, 0, 2 * SW * SS - 1, 2 * SH * SS - 1), radius=RADIUS * SS, fill=fill
    )
    box = box.resize((2 * SW, 2 * SH), Image.LANCZOS)
    corners = {
        "nw": (0, 0, SW, SH),
        "ne": (SW, 0, 2 * SW, SH),
        "sw": (0, SH, SW, 2 * SH),
        "se": (SW, SH, 2 * SW, 2 * SH),
    }
    out = {name: box.crop(c) for name, c in corners.items()}
    # the straight edges between the corners: solid, and 1 px along the axis
    # GRUB stretches, so the slice is a colour rather than an image to scale
    out["n"] = Image.new("RGBA", (1, SH), fill)
    out["s"] = Image.new("RGBA", (1, SH), fill)
    out["w"] = Image.new("RGBA", (SW, 1), fill)
    out["e"] = Image.new("RGBA", (SW, 1), fill)
    out["c"] = Image.new("RGBA", (1, 1), fill)
    for name, im in out.items():
        im.save(os.path.join(OUT, "%s_%s.png" % (prefix, name)))
    return sorted(out)


def main():
    os.makedirs(OUT, exist_ok=True)
    starfield(BG_W, BG_H).save(os.path.join(OUT, "background.png"))
    print("background.png %dx%d" % (BG_W, BG_H))
    lavender = P.rgb("lavender") + (255,)
    print("select_*.png", slices("select", lavender))
    print("item_*.png", slices("item", (0, 0, 0, 0)))


if __name__ == "__main__":
    main()
