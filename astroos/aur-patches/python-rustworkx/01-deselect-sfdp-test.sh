#!/usr/bin/env bash
# rustworkx 0.18.1 builds and passes 2389 of 2390 tests in the hermetic
# container; the one failure is tests/visualization/test_graphviz.py::
# TestGraphvizDraw::test_method, where graphviz's `sfdp -T png` dies with
# SIGABRT (a graphviz/sfdp crash in the container, not a rustworkx defect;
# observed 2026-09-05). Deselect that single test; the rest of check() runs.
# Council R3 D6 aur-patches mechanism. Runs in the cloned pkg dir.
set -e
sed -i 's|-m pytest -o addopts=""|-m pytest -o addopts="" --deselect tests/visualization/test_graphviz.py::TestGraphvizDraw::test_method|' PKGBUILD
grep -q 'deselect tests/visualization/test_graphviz.py' PKGBUILD
