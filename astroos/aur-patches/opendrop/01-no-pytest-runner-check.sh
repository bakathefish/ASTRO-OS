#!/usr/bin/env bash
# opendrop 0.13.0-3: check() runs `python setup.py pytest` through
# pytest-runner, whose `ptr` module imports pkg_resources, removed from
# setuptools on the Python 3.14 stack (run 3, 2026-09-05: "No module named
# 'pkg_resources'", failure in check()). The test suite is upstream's, not a
# packaging check; drop it together with its only checkdepend
# (python-pytest-runner also left aur.list, R3 D6 maintenance surface).
set -euo pipefail
grep -q '^checkdepends=(.python-pytest-runner.)$' PKGBUILD
sed -i -e '/^checkdepends=(.python-pytest-runner.)$/d' -e '/^check() {$/,/^}$/d' PKGBUILD
! grep -q 'pytest' PKGBUILD
