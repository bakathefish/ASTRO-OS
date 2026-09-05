#!/usr/bin/env bash
# python-parfive's PKGBUILD builds a python-parfive-doc split with sphinx and
# four docs-only makedepends, two of them AUR-only (python-sphinx-automodapi,
# python-sphinx_contributors); sphinx_contributors 0.3.0 no longer builds under
# flit_core 4 ("[tool.flit.metadata] table is no longer supported",
# 2026-09-05). The -doc split is never shipped by AstroOS. Drop the docs build:
# single pkgname, no sphinx makedepends, no docs make step. pkgbase stays, so
# makepkg keeps calling package_python-parfive(); the unused -doc function and
# the optdepends hint on it are harmless.
# Council R3 D6 aur-patches mechanism. Runs in the cloned pkg dir.
set -e
sed -i 's/^pkgname=(.*/pkgname=("python-${_pyname}")/' PKGBUILD
sed -i "/'python-sphinx-automodapi'/d; /'python-sphinx-autodoc-typehints'/d; /'python-sphinx-book-theme'/d; /'python-sphinx_contributors'/d" PKGBUILD
sed -i '/msg "Building Docs"/d; /make -C docs html/d' PKGBUILD
grep -q 'pkgname=("python-${_pyname}")' PKGBUILD
! grep -q 'make -C docs' PKGBUILD
! grep -q 'sphinx' PKGBUILD
