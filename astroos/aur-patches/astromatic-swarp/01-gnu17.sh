#!/usr/bin/env bash
# swarp 2.41.5 (AUR PKGBUILD last touched 2020) declares gammln() K&R-style
# with empty parentheses. C23, the GCC 15 default, turns that into a
# zero-parameter prototype, so the one-argument calls in coadd.c are hard
# errors ("too many arguments to function 'gammln'; expected 0, have 1",
# observed 2026-09-05). Build as gnu17 instead; no source change.
# Council R3 D6 aur-patches mechanism. Runs in the cloned pkg dir.
set -e
sed -i 's|\./configure --prefix=/usr|CFLAGS="$CFLAGS -std=gnu17" ./configure --prefix=/usr|' PKGBUILD
grep -q 'std=gnu17' PKGBUILD
