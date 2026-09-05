#!/usr/bin/env bash
# The geant4 PKGBUILD sets PKGEXT='.pkg.tar' (uncompressed, to save the
# maintainer's build time). That would put a ~1 GiB package in the hosted
# repo and on every client download. Restore the Arch default: zstd, which
# makepkg compresses multi-threaded in a few minutes on the build VM.
# (The build script tolerates any PKGEXT regardless; this is about size.)
# Council R3 D6 aur-patches mechanism. Runs in the cloned pkg dir.
set -e
sed -i "s/^PKGEXT=.*/PKGEXT='.pkg.tar.zst'/" PKGBUILD
grep -q "PKGEXT='.pkg.tar.zst'" PKGBUILD
