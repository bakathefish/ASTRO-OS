#!/usr/bin/env bash
# python-qiskit: qiskit/qasm2/parse.py does `from typing_extensions import
# Unpack`, but the PKGBUILD's depends list omits python-typing_extensions
# (import smoke in run 3, 2026-09-05: "No module named 'typing_extensions'").
# Declare it so a clean install (the D6 smoke, and every user) works.
set -euo pipefail
grep -q '^depends=($' PKGBUILD
grep -q 'python-typing_extensions' PKGBUILD || sed -i 's/^depends=($/depends=(\n    python-typing_extensions/' PKGBUILD
grep -q '^    python-typing_extensions$' PKGBUILD
