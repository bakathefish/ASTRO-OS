#!/usr/bin/env python3
"""The AstroOS palette: the single source of truth for every colour the OS
shows, from the boot menu to the terminal prompt.

Every value here is derived from the two files that already define the brand:
logo.py (the procedural logo: sphere, band and glow colours) and assetgen.py
(the wallpaper, login background and slides: the deep-space gradient, nebula
and text colours). Nothing below is a new hue except the two semantic colours
every desktop needs (a warning amber and an error rose), which are muted so
they sit inside the same space rather than shouting from outside it.

Roles, not moods: each entry names WHERE the colour goes, so a themed file
(KDE colour scheme, Konsole scheme, Plymouth theme, GRUB theme, Calamares
branding, fish/fastfetch colours) can be checked mechanically against this
table by palette-check.py. A themed file may use only these colours.

Values are 6-digit lowercase hex without the '#'. Helpers at the bottom give
the other spellings the consumers want (KDE "r,g,b", Plymouth "0xrrggbb",
Limine bare "rrggbb", ANSI "38;2;r;g;b").
"""

PALETTE = {
    # deep space: the backgrounds, darkest first. SPACE_TOP/SPACE_BOTTOM are
    # assetgen's gradient; the UI surfaces step up from there in lightness with
    # the same indigo cast, so a window never looks grey against the wallpaper.
    "space_top": "03020a",  # boot splash / GRUB / ksplash gradient top
    "space_bottom": "0e0820",  # gradient bottom; lock and logout overlays
    "view": "120e22",  # text views, lists, editors, the terminal
    "window": "1b1630",  # window chrome, dialogs, panel
    "button": "28223f",  # buttons, raised surfaces, input fields
    "header": "161129",  # title bars, header bars, settings sidebars
    "tooltip": "231c3a",  # tooltips, popups
    "line": "332b4f",  # separators, frames, inactive borders
    # text, from assetgen (TEXT_MAIN / TEXT_SUB / TEXT_DIM) plus a disabled step
    "text": "e8e6f5",
    "text_sub": "c8c4de",
    "text_dim": "9692b2",
    "text_disabled": "6b6688",
    "selection_text": "f8e2f6",  # logo SPHERE_LIGHT: text on a lavender selection
    # brand accents, from the logo
    "lavender": "8658b4",  # BLOTCH: selection, accent, progress, focus fill
    "lavender_hi": "a679c9",  # focus ring, cursor, active indicator
    "orchid": "c99cdc",  # SPHERE_MID: hover, secondary accent, magenta
    "pink": "e29ef0",  # GLOW_PINK: visited links, bright magenta
    "cyan": "4ac0da",  # BAND_IN: links, information
    "cyan_hi": "62e2ec",  # GLOW_CYAN: active/attention text, bright cyan
    "teal": "2cb8ab",  # LINE_IN: positive, success, ANSI green
    "teal_hi": "5fd6c9",  # bright green
    "indigo": "7c6bd0",  # ANSI blue (a lavender-leaning blue, not sky)
    "indigo_hi": "9c8ce6",  # bright blue
    # the two semantic hues that are not in the logo, muted to the same depth
    "amber": "e2b46a",  # neutral / warning, ANSI yellow
    "amber_hi": "f0cb8c",  # bright yellow
    "rose": "e0679a",  # negative / error, ANSI red
    "rose_hi": "f08ab5",  # bright red
    # The light scheme (AstroOS Light, pkgs/astroos-theme/gen-colors.py):
    # paper surfaces with the same violet cast the dark ones have, and the
    # five semantic hues deepened until they pass 4.2:1 on the lightest
    # paper. Text on paper reuses the dark roles the other way round: window
    # is the ink, text_disabled the dimmed ink, text_dim the disabled ink.
    "paper_view": "fbfaff",  # text views, lists, editors
    "paper_button": "f8f6fd",  # buttons, raised surfaces, inputs
    "paper": "f0edf8",  # window chrome, dialogs, panel, tooltips
    "paper_header": "e8e4f3",  # title bars, header bars, sidebars
    "paper_line": "d3cde3",  # separators, frames, alternate rows
    "cyan_deep": "0c7085",  # links, active and attention text on paper
    "teal_deep": "12716a",  # positive on paper
    "amber_deep": "8a6212",  # neutral / warning on paper
    "rose_deep": "ad3d74",  # negative / error on paper
    "orchid_deep": "8a44ad",  # visited links on paper
}

# The 16 ANSI colours every terminal surface (Konsole, Limine, fish, the
# TTY) maps to, by role name from PALETTE. Semantics are kept (red is the
# error colour, green is success) so tools that colour by convention still
# read correctly; only the hues are pulled into the brand.
ANSI = {
    "black": "window",
    "bright_black": "text_disabled",
    "red": "rose",
    "bright_red": "rose_hi",
    "green": "teal",
    "bright_green": "teal_hi",
    "yellow": "amber",
    "bright_yellow": "amber_hi",
    "blue": "indigo",
    "bright_blue": "indigo_hi",
    "magenta": "orchid",
    "bright_magenta": "pink",
    "cyan": "cyan",
    "bright_cyan": "cyan_hi",
    "white": "text_sub",
    "bright_white": "text",
    "foreground": "text",
    "background": "view",
    "cursor": "lavender_hi",
}

ANSI_ORDER = ("black", "red", "green", "yellow", "blue", "magenta", "cyan", "white")


def hexval(role):
    """'8658b4' for a role name."""
    return PALETTE[role]


def rgb(role):
    """(134, 88, 180) for a role name."""
    h = PALETTE[role]
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))


def kde(role):
    """'134,88,180': the form KDE .colors and Konsole .colorscheme files use."""
    return ",".join(str(c) for c in rgb(role))


def css(role):
    """'#8658b4': stylesheets, GRUB theme.txt, branding.desc, QML."""
    return "#" + PALETTE[role]


def plymouth(role):
    """'0x8658b4': Plymouth theme files."""
    return "0x" + PALETTE[role]


def ansi_truecolor(role, background=False):
    """'38;2;134;88;180' (or 48;2 for a background): SGR truecolor sequence."""
    r, g, b = rgb(role)
    return "%d;2;%d;%d;%d" % (48 if background else 38, r, g, b)


def limine_palette(bright=False):
    """'1b1630;e0679a;...': Limine's term_palette / term_palette_bright value."""
    names = [("bright_" if bright else "") + n for n in ANSI_ORDER]
    return ";".join(PALETTE[ANSI[n]] for n in names)


def all_hex():
    """Every hex value a themed file is allowed to contain."""
    return set(PALETTE.values())


if __name__ == "__main__":
    import sys

    if len(sys.argv) == 2 and sys.argv[1] in PALETTE:
        r = sys.argv[1]
        print("%-14s #%s  kde %s  plymouth %s" % (r, hexval(r), kde(r), plymouth(r)))
        sys.exit(0)
    for role, h in PALETTE.items():
        print("%-14s #%s  %s" % (role, h, kde(role)))
    print()
    print("limine term_palette:        " + limine_palette())
    print("limine term_palette_bright: " + limine_palette(bright=True))
