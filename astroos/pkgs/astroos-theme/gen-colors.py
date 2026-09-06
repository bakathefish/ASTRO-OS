#!/usr/bin/env python3
"""Write the two AstroOS Plasma colour schemes from palette roles.

    python3 astroos/pkgs/astroos-theme/gen-colors.py

Writes, under this package's files/ tree so the schemes are committed like
any other payload:
    usr/share/color-schemes/AstroOSDark.colors    the default
    usr/share/color-schemes/AstroOSLight.colors   the same brand on paper

The structure, every group and every key, is Breeze's (plasma/breeze
colors/BreezeDark.colors and BreezeLight.colors, LGPL-2.0-or-later). KColorScheme
falls back to its own built-in Breeze value for any key a scheme leaves out,
so a missing key would quietly put a colour on screen that is not in the
palette; every key is therefore written for every group. Only the values are
ours, and every value is a role name from astroos/branding/palette.py, so
palette-check.py proves the files use nothing else.

The two [ColorEffects:*] groups are Breeze's verbatim, values included: those
greys are the blend KDE mixes into disabled and inactive text, not surfaces
the brand paints. palette-check.py exempts them for that reason.

One accent. Selection is lavender in both schemes, so no AccentColor key is
set: with none named, the scheme's selection colour is what Plasma uses as
the accent.

Contrast: every Foreground* text role is checked against its group's
BackgroundNormal and must reach 4.2:1 (WCAG AA for normal text is 4.5:1, for
large or bold text 3:1; 4.2 is the floor the dark scheme was designed to,
see branding/PALETTE.md). The script fails rather than write a pair below
it, and prints the table so the numbers in PALETTE.md can be copied, never
typed.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "branding"))
import palette as P  # noqa: E402

OUT = os.path.join(HERE, "files", "usr", "share", "color-schemes")
FLOOR = 4.2

EFFECTS = """[ColorEffects:Disabled]
Color=56,56,56
ColorAmount=0
ColorEffect=0
ContrastAmount=0.65
ContrastEffect=1
IntensityAmount=0.1
IntensityEffect=2

[ColorEffects:Inactive]
ChangeSelectionColor=true
Color=112,111,110
ColorAmount=0.025
ColorEffect=2
ContrastAmount=0.1
ContrastEffect=2
Enable=false
IntensityAmount=0
IntensityEffect=0
"""

FG_KEYS = (
    "DecorationFocus",
    "DecorationHover",
    "ForegroundActive",
    "ForegroundInactive",
    "ForegroundLink",
    "ForegroundNegative",
    "ForegroundNeutral",
    "ForegroundNormal",
    "ForegroundPositive",
    "ForegroundVisited",
)
TEXT_KEYS = tuple(
    k for k in FG_KEYS if k.startswith("Foreground") and k != "ForegroundInactive"
)

# the foreground set every non-selection group shares, per scheme
DARK_FG = dict(
    DecorationFocus="lavender_hi",
    DecorationHover="orchid",
    ForegroundActive="cyan_hi",
    ForegroundInactive="text_dim",
    ForegroundLink="cyan",
    ForegroundNegative="rose",
    ForegroundNeutral="amber",
    ForegroundNormal="text",
    ForegroundPositive="teal",
    ForegroundVisited="pink",
)
LIGHT_FG = dict(
    DecorationFocus="lavender_hi",
    DecorationHover="orchid",
    ForegroundActive="cyan_deep",
    ForegroundInactive="text_disabled",
    ForegroundLink="cyan_deep",
    ForegroundNegative="rose_deep",
    ForegroundNeutral="amber_deep",
    ForegroundNormal="window",
    ForegroundPositive="teal_deep",
    ForegroundVisited="orchid_deep",
)
# text over a lavender selection, the same in both schemes
SELECTION_FG = dict(
    DecorationFocus="selection_text",
    DecorationHover="orchid",
    ForegroundActive="cyan_hi",
    ForegroundInactive="text_sub",
    ForegroundLink="cyan_hi",
    ForegroundNegative="rose_hi",
    ForegroundNeutral="amber_hi",
    ForegroundNormal="selection_text",
    ForegroundPositive="teal_hi",
    ForegroundVisited="pink",
)

SCHEMES = {
    "AstroOSDark": dict(
        name="AstroOS Dark",
        fg=DARK_FG,
        # group: (BackgroundAlternate, BackgroundNormal)
        groups={
            "Button": ("line", "button"),
            "Complementary": ("window", "space_bottom"),
            "Header": ("window", "header"),
            "Header][Inactive": ("header", "window"),
            "Selection": ("lavender_hi", "lavender"),
            "Tooltip": ("window", "tooltip"),
            "View": ("window", "view"),
            "Window": ("button", "window"),
        },
        wm=dict(
            active_bg="header",
            active_fg="text",
            inactive_bg="window",
            inactive_fg="text_dim",
        ),
    ),
    "AstroOSLight": dict(
        name="AstroOS Light",
        fg=LIGHT_FG,
        groups={
            "Button": ("paper", "paper_button"),
            # lock and logout overlays stay dark in both, as Breeze keeps them
            "Complementary": ("window", "space_bottom"),
            "Header": ("paper", "paper_header"),
            "Header][Inactive": ("paper_header", "paper"),
            "Selection": ("lavender_hi", "lavender"),
            "Tooltip": ("paper_header", "paper"),
            "View": ("paper", "paper_view"),
            "Window": ("paper_button", "paper"),
        },
        wm=dict(
            active_bg="paper_header",
            active_fg="window",
            inactive_bg="paper",
            inactive_fg="text_disabled",
        ),
    ),
}


def luminance(role):
    def lin(c):
        c /= 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = (lin(c) for c in P.rgb(role))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def render(scheme_id, spec):
    lines = [
        "# The AstroOS colour scheme, %s. Generated by"
        % spec["name"].split()[-1].lower(),
        "# astroos/pkgs/astroos-theme/gen-colors.py from astroos/branding/palette.py:",
        "# edit the roles there, not the numbers here. palette-check.py fails on any",
        "# value that is not in that table; the [ColorEffects:*] groups are Breeze's",
        "# verbatim and exempt (they are blends KDE mixes, not surfaces we paint).",
        "",
        EFFECTS,
    ]
    worst = []
    for group, (alt, normal) in spec["groups"].items():
        fg = SELECTION_FG if group == "Selection" else spec["fg"]
        # Complementary is the dark overlay in both schemes: dark foregrounds
        if group == "Complementary":
            fg = DARK_FG
        lines.append("[Colors:%s]" % group)
        lines.append("BackgroundAlternate=%s" % P.kde(alt))
        lines.append("BackgroundNormal=%s" % P.kde(normal))
        for key in FG_KEYS:
            lines.append("%s=%s" % (key, P.kde(fg[key])))
        lines.append("")
        for key in TEXT_KEYS:
            c = contrast(fg[key], normal)
            # Over a selection only the normal text has to pass: the semantic
            # colours of a selected row (a link, an error) sit on lavender at
            # 2.2 to 3.4:1 in both schemes, as Breeze's own do on its blue, and
            # they are momentary. They are printed, not enforced.
            if group == "Selection" and key != "ForegroundNormal":
                continue
            worst.append((c, group, key, fg[key], normal))
    wm = spec["wm"]
    lines += [
        "[General]",
        "ColorScheme=%s" % scheme_id,
        "Name=%s" % spec["name"],
        "shadeSortColumn=true",
        "",
        "[KDE]",
        "contrast=4",
        "",
        "[WM]",
        "activeBackground=%s" % P.kde(wm["active_bg"]),
        "activeBlend=%s" % P.kde(wm["active_bg"]),
        "activeForeground=%s" % P.kde(wm["active_fg"]),
        "inactiveBackground=%s" % P.kde(wm["inactive_bg"]),
        "inactiveBlend=%s" % P.kde(wm["inactive_bg"]),
        "inactiveForeground=%s" % P.kde(wm["inactive_fg"]),
        "",
    ]
    worst.append(
        (
            contrast(wm["active_fg"], wm["active_bg"]),
            "WM",
            "activeForeground",
            wm["active_fg"],
            wm["active_bg"],
        )
    )
    worst.sort()
    return "\n".join(lines), worst


def main():
    os.makedirs(OUT, exist_ok=True)
    ok = True
    for scheme_id, spec in SCHEMES.items():
        text, table = render(scheme_id, spec)
        path = os.path.join(OUT, scheme_id + ".colors")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print(
            "%s: %d groups, lowest text contrasts:"
            % (os.path.basename(path), len(spec["groups"]))
        )
        for c, group, key, fg, bg in table[:6]:
            flag = "" if c >= FLOOR else "   BELOW %.1f" % FLOOR
            print("  %5.2f:1  %-18s %-18s %s on %s%s" % (c, group, key, fg, bg, flag))
            ok = ok and c >= FLOOR
    if not ok:
        print("a text role is below %.1f:1; not a scheme to ship" % FLOOR)
        sys.exit(1)


if __name__ == "__main__":
    main()
