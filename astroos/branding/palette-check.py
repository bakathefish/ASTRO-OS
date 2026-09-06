#!/usr/bin/env python3
"""Assert that themed files use only palette colours.

Usage: palette-check.py FILE...   (exit 1 on any colour outside palette.py)

Scans each file for the spellings the consumers use and checks every colour it
finds against PALETTE:
  #rrggbb          stylesheets, GRUB theme.txt, branding.desc, QML, fish, jsonc
  0xrrggbb         Plymouth theme files
  key=r,g,b        KDE .colors and Konsole .colorscheme files
  term_*: aa;bb;.. Limine palette lines (bare hex, ';'-separated), and the
                   single bare-hex form term_foreground: rrggbb
A [ColorEffects:*] section in a .colors file is exempt: those greys are the
disabled/inactive blend colours KDE mixes in, copied from Breeze, and are not
brand surfaces. Alpha-suffixed Limine values (rrggbbaa) are compared on their
first six digits.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from palette import all_hex  # noqa: E402

ALLOWED = all_hex()
HEX_HASH = re.compile(r"#([0-9a-fA-F]{6})\b")
HEX_0X = re.compile(r"\b0x([0-9a-fA-F]{6})\b")
KDE_TRIPLET = re.compile(r"^\s*[A-Za-z0-9_]+\s*=\s*(\d{1,3}),(\d{1,3}),(\d{1,3})\s*$")
LIMINE = re.compile(r"^\s*term_[a-z_]+:\s*([0-9a-fA-F;]+)\s*(\\n)?\s*$")
SECTION = re.compile(r"^\s*\[([^\]]+)\]\s*$")


def colours_in(path):
    """Yield (line_number, hex, text) for every colour spelled in the file."""
    section = ""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            m = SECTION.match(line)
            if m:
                section = m.group(1)
                continue
            if section.startswith("ColorEffects:"):
                continue
            # a line that must carry a foreign value (a bootloader's own
            # transparency sentinel, an upstream attribution) says so
            if "palette-check: ignore" in line:
                continue
            for m in HEX_HASH.finditer(line):
                yield n, m.group(1).lower(), line.strip()
            for m in HEX_0X.finditer(line):
                yield n, m.group(1).lower(), line.strip()
            m = KDE_TRIPLET.match(line)
            if m:
                r, g, b = (int(x) for x in m.groups())
                if max(r, g, b) <= 255:
                    yield n, "%02x%02x%02x" % (r, g, b), line.strip()
            # Limine lines may sit inside a Python write("...\n") in apply.sh
            # or main.py, so strip the quoting before matching
            core = line.strip().strip("\"')( ").replace('config_file.write("', "")
            m = LIMINE.match(core)
            if m:
                for tok in m.group(1).split(";"):
                    if len(tok) >= 6:
                        yield n, tok[:6].lower(), line.strip()


def main(paths):
    bad = 0
    seen = 0
    for p in paths:
        if os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                for f in files:
                    seen += 1
                    bad += check(os.path.join(root, f))
        else:
            seen += 1
            bad += check(p)
    print("palette-check: %d file(s), %d colour(s) outside the palette" % (seen, bad))
    return 1 if bad else 0


def check(path):
    bad = 0
    for n, h, text in colours_in(path):
        if h not in ALLOWED:
            bad += 1
            print("%s:%d: #%s is not in palette.py: %s" % (path, n, h, text))
    return bad


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
