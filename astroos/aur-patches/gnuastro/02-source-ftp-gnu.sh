#!/usr/bin/env bash
# The PKGBUILD fetches the tarball via http://ftpmirror.gnu.org/, a redirector
# to a random mirror; on 2026-09-05 the chosen mirror reset the connection
# mid-download ("curl: (56) Recv failure") and the hermetic build failed for a
# reason that has nothing to do with the recipe. Use the canonical GNU host
# over TLS. makepkg still validates the tarball against the recipe's sha256.
# Council R3 D6 aur-patches mechanism. Runs in the cloned pkg dir.
set -e
sed -i 's|http://ftpmirror.gnu.org/|https://ftp.gnu.org/gnu/|' PKGBUILD
grep -q 'https://ftp.gnu.org/gnu/' PKGBUILD
