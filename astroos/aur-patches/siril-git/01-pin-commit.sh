#!/usr/bin/env bash
# siril-git: pin the upstream commit (council R4 review D-F: an unpinned -git
# package builds whatever master is at build time, which makes the signed
# aur-map.lock non-reproducible and lets any master breakage block a publish
# cycle). Bump the sha deliberately, with a build, when a newer master is
# wanted. Revert to the `siril` release package at the first release that
# supports OpenCV 5 (>1.4.4).
set -euo pipefail
commit=0f47ce735e166cf4a3e6697e0bd923859d924a21   # master 2026-09-05
grep -q '"git+$url.git"' PKGBUILD || { echo "siril-git PKGBUILD source line changed; re-check the pin patch" >&2; exit 1; }
sed -i "s|\"git+\$url.git\"|\"git+\$url.git#commit=$commit\"|" PKGBUILD
grep -q "#commit=$commit" PKGBUILD
