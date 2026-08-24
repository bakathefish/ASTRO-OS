#!/usr/bin/env bash
# Build the AstroOS ISO with mkarchiso, reproducibly, inside a pinned container.
# Council R1: containerized mkarchiso at a pinned image digest + reproducibility gate.
#
# Requires: docker or podman on the host. The host does NOT need to be Arch —
# the Arch toolchain lives inside the container. Run from repo root or anywhere.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # astroos/ profile dir
repo="$(cd "$here/.." && pwd)"
outdir="$repo/out"
workdir="$repo/work"

# Pin the builder image by digest for reproducibility. Update deliberately.
# archlinux:latest as a placeholder tag — replace TAG with a @sha256:... digest
# once you pick a build date. Kept as tag here so the script runs before you pin.
BUILDER_IMAGE="${ASTROOS_BUILDER_IMAGE:-docker.io/archlinux:base-devel}"

runtime=""
command -v podman >/dev/null 2>&1 && runtime=podman
[[ -z "$runtime" ]] && command -v docker >/dev/null 2>&1 && runtime=docker
[[ -z "$runtime" ]] && { echo "Need docker or podman on the host." >&2; exit 1; }

echo ">> Regenerating packages.x86_64 from meta lists..."
bash "$here/scripts/gen-packages.sh"

mkdir -p "$outdir" "$workdir"

echo ">> Building ISO with $runtime using $BUILDER_IMAGE ..."
# Named volume for the pacman package cache: pacstrap runs with -c (host
# cache), so a failed attempt never re-downloads what already landed.
$runtime volume create astroos-pacman-cache >/dev/null 2>&1 || true

# --ulimit: pacstrap verifies ~1800 signatures in one transaction; at the
# default container nofile soft limit gpgme exhausts fds after ~990 packages
# and every later verification fails as "invalid or corrupted (PGP signature)".
$runtime run --rm --privileged \
  --ulimit nofile=1048576:1048576 \
  -v "$repo":/build -w /build \
  -v astroos-pacman-cache:/var/cache/pacman/pkg \
  "$BUILDER_IMAGE" bash -euo pipefail -c '
    ulimit -n 1048576 || true
    echo ">> nofile limit: $(ulimit -n)"
    # The image default mirror (fastly) throttles big transactions; pin a
    # geo mirror with fallbacks. pacman skips a mirror after repeated errors.
    printf "%s\n" \
      "Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch" \
      "Server = https://mirrors.kernel.org/archlinux/\$repo/os/\$arch" \
      "Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch" \
      > /etc/pacman.d/mirrorlist
    pacman -Sy --noconfirm --needed archiso git
    # CachyOS signing key: the profile pacman.conf enables [cachyos] with
    # SigLevel Required, so the builder keyring must trust it before mkarchiso
    # resolves linux-cachyos / linux-cachyos-lts.
    pacman-key --init
    # Arch packager keys: --init alone yields a bare keyring (only a master
    # key), so every [core]/[extra] package fails "invalid PGP signature".
    # Populate from the archlinux-keyring shipped in the builder image.
    pacman-key --populate archlinux
    pacman-key --recv-keys F3B607488DB35A47 --keyserver hkps://keyserver.ubuntu.com
    pacman-key --lsign-key F3B607488DB35A47
    # (AUR bootstrap + BlackArch strap hooks run from airootfs customize script)
    mkarchiso -v -w /build/work -o /build/out /build/astroos
  '

echo ">> Emitting reproducibility artifacts..."
cd "$outdir"
iso=$(ls -1t *.iso 2>/dev/null | head -1 || true)
if [[ -n "${iso:-}" ]]; then
  sha256sum "$iso" > "sha256sums.txt"
  cp "$here/packages.x86_64" "manifest.pkglist" 2>/dev/null || true
  {
    echo "iso=$iso"
    echo "builder_image=$BUILDER_IMAGE"
    echo "profile=astroos"
  } > "build-metadata.txt"
  echo ">> Done: $outdir/$iso"
else
  echo "!! No ISO produced — check mkarchiso output above." >&2
  exit 1
fi
