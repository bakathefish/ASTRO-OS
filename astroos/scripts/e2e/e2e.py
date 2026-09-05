#!/usr/bin/env python3
"""Minimal QMP driver for the AstroOS end-to-end install guest (no GUI needed).

e2e.py shot <png>            screenshot (prints WxH)
e2e.py click <x> <y> [--double|--right]
e2e.py key <qcode> [mod+mod] e.g. key ret, key tab, key t ctrl+alt
e2e.py type <text>           US keymap text (letters, digits, punctuation, newline)
e2e.py hmp <command>         human monitor command, e.g. hostfwd_add n0 tcp::2222-:22
e2e.py quit                  power off the guest hard

The guest is started by e2e-start.sh; the QMP socket lives in $E2E_DIR
(default /tmp/e2e). Calamares has no unattended mode, so an install is driven
by screenshots plus absolute mouse clicks and typed text (see README.md).
"""

import json
import os
import socket
import struct
import sys
import time

D = os.environ.get("E2E_DIR", "/tmp/e2e")
SOCK = os.path.join(D, "qmp.sock")
PROBE = os.path.join(D, "_probe.png")


def qmp(cmds):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    f = s.makefile("rw")
    f.readline()  # greeting

    def do(cmd, args=None):
        msg = {"execute": cmd}
        if args:
            msg["arguments"] = args
        f.write(json.dumps(msg) + "\n")
        f.flush()
        while True:
            line = f.readline()
            if not line:
                raise SystemExit("qmp closed")
            r = json.loads(line)
            if "return" in r or "error" in r:
                if "error" in r:
                    raise SystemExit(f"qmp error for {cmd}: {r['error']}")
                return r

    do("qmp_capabilities")
    out = [do(c, a) for c, a in cmds]
    s.close()
    return out


def png_size(path):
    with open(path, "rb") as fh:
        head = fh.read(24)
    return struct.unpack(">II", head[16:24])


def shot(path):
    qmp([("screendump", {"filename": path, "format": "png"})])
    return png_size(path)


def move(x, y, w, h):
    ax = int(x * 32767 / w)
    ay = int(y * 32767 / h)
    ev = [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
    ]
    qmp([("input-send-event", {"events": ev})])


def click(x, y, button="left", double=False):
    w, h = shot(PROBE)
    move(x, y, w, h)
    time.sleep(0.25)
    press = [{"type": "btn", "data": {"down": True, "button": button}}]
    rel = [{"type": "btn", "data": {"down": False, "button": button}}]
    for _ in range(2 if double else 1):
        qmp([("input-send-event", {"events": press})])
        time.sleep(0.1)
        qmp([("input-send-event", {"events": rel})])
        time.sleep(0.15)


def key(qcode, mods=()):
    def k(code, down):
        return {
            "type": "key",
            "data": {"down": down, "key": {"type": "qcode", "data": code}},
        }

    evs = (
        [k(m, True) for m in mods]
        + [k(qcode, True), k(qcode, False)]
        + [k(m, False) for m in reversed(mods)]
    )
    qmp([("input-send-event", {"events": evs})])
    time.sleep(0.07)


SYMBOLS = {
    " ": ("spc", ()),
    ".": ("dot", ()),
    "-": ("minus", ()),
    "_": ("minus", ("shift",)),
    "/": ("slash", ()),
    "?": ("slash", ("shift",)),
    ",": ("comma", ()),
    "<": ("comma", ("shift",)),
    ">": ("dot", ("shift",)),
    "=": ("equal", ()),
    "+": ("equal", ("shift",)),
    "@": ("2", ("shift",)),
    "!": ("1", ("shift",)),
    "#": ("3", ("shift",)),
    "$": ("4", ("shift",)),
    "%": ("5", ("shift",)),
    "^": ("6", ("shift",)),
    "&": ("7", ("shift",)),
    "*": ("8", ("shift",)),
    "(": ("9", ("shift",)),
    ")": ("0", ("shift",)),
    ":": ("semicolon", ("shift",)),
    ";": ("semicolon", ()),
    "'": ("apostrophe", ()),
    '"': ("apostrophe", ("shift",)),
    "[": ("bracket_left", ()),
    "]": ("bracket_right", ()),
    "{": ("bracket_left", ("shift",)),
    "}": ("bracket_right", ("shift",)),
    "\\": ("backslash", ()),
    "|": ("backslash", ("shift",)),
    "`": ("grave_accent", ()),
    "~": ("grave_accent", ("shift",)),
    "\n": ("ret", ()),
    "\t": ("tab", ()),
}


def type_text(text):
    for ch in text:
        if ch.isalpha():
            key(ch.lower(), ("shift",) if ch.isupper() else ())
        elif ch.isdigit():
            key(ch)
        elif ch in SYMBOLS:
            code, mods = SYMBOLS[ch]
            key(code, mods)
        else:
            raise SystemExit(f"no key mapping for {ch!r}")


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    cmd = sys.argv[1]
    if cmd == "shot":
        w, h = shot(sys.argv[2])
        print(f"{w}x{h}")
    elif cmd == "click":
        x, y = int(sys.argv[2]), int(sys.argv[3])
        click(
            x,
            y,
            button="right" if "--right" in sys.argv else "left",
            double="--double" in sys.argv,
        )
        print(f"clicked {x},{y}")
    elif cmd == "key":
        mods = tuple(sys.argv[3].split("+")) if len(sys.argv) > 3 else ()
        key(sys.argv[2], mods)
        print("key sent")
    elif cmd == "type":
        type_text(sys.argv[2])
        print("typed")
    elif cmd == "hmp":
        r = qmp([("human-monitor-command", {"command-line": " ".join(sys.argv[2:])})])
        print(r[0].get("return", ""))
    elif cmd == "quit":
        qmp([("quit", None)])
        print("quit sent")
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
