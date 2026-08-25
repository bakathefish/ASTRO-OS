#!/usr/bin/env bash
# gnuastro's AUR PKGBUILD depends on bare "libjpeg"; current Arch
# libjpeg-turbo no longer Provides that name (verified 2026-08-25, pacman -S
# --print libjpeg => target not found). Rewrite the depends entry.
# Council R3.1 P4 / R3 D6 patch mechanism. Runs in the cloned pkg dir.
set -e
sed -i 's/libjpeg\([^-]\|$\)/libjpeg-turbo\1/g' PKGBUILD
grep -q 'libjpeg-turbo' PKGBUILD
