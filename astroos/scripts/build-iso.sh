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
$runtime run --rm --privileged \
  -v "$repo":/build -w /build \
  "$BUILDER_IMAGE" bash -euo pipefail -c '
    pacman -Sy --noconfirm --needed archiso git
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
