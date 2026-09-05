#!/usr/bin/env bash
# geant4's PKGBUILD depends on 'zlib>=1.2.3'. Installed CachyOS systems carry
# zlib-ng-compat, which provides plain 'zlib' with no version, so pacman cannot
# satisfy the versioned dependency from it, pulls the real zlib and dies on the
# zlib/zlib-ng-compat conflict: the Calamares "packages" job failed exactly
# there in the 2026-09-05 end-to-end install. zlib-ng 2.x is a complete zlib
# 1.3 replacement, so the floor carries no information; drop it. Only the
# dependency string changes, no source or build flag.
# Council R3 D6 aur-patches mechanism. Runs in the cloned pkg dir.
set -e
grep -qE "zlib>=[0-9.]+" PKGBUILD
sed -i -E "s/zlib>=[0-9.]+/zlib/g" PKGBUILD
! grep -qE "zlib>=" PKGBUILD
grep -qw "zlib" PKGBUILD
# New file name for the changed metadata (Arch rebuild convention, pkgrel .1),
# so caches holding the first build never see a same-name checksum mismatch and
# installed systems pick it up as an upgrade.
grep -q "^pkgrel=1$" PKGBUILD
sed -i "s/^pkgrel=1$/pkgrel=1.1/" PKGBUILD
