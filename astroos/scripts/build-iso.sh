#!/usr/bin/env bash
# Build the AstroOS ISO: pinned CachyOS-Live-ISO base + AstroOS delta,
# inside a container (host needs only docker/podman, not Arch).
# Owner directive 7a / ledger R1.2: lift, don't rebuild — we configure and
# skin CachyOS; custom surface = package additions, airootfs overlay, identity.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # astroos/ dir
repo="$(cd "$here/.." && pwd)"
outdir="$repo/out"
workdir="$repo/work"

# shellcheck source=../base.lock
source "$here/base.lock"

BUILDER_IMAGE="${ASTROOS_BUILDER_IMAGE:-docker.io/archlinux:base-devel}"

runtime=""
command -v podman >/dev/null 2>&1 && runtime=podman
[[ -z "$runtime" ]] && command -v docker >/dev/null 2>&1 && runtime=docker
[[ -z "$runtime" ]] && { echo "Need docker or podman on the host." >&2; exit 1; }

echo ">> Regenerating astroos-additions.x86_64 from meta lists..."
bash "$here/scripts/gen-packages.sh"

mkdir -p "$outdir" "$workdir"

echo ">> Building ISO with $runtime using $BUILDER_IMAGE ..."
# Named volume for the pacman package cache: pacstrap runs with -c, so a
# failed attempt never re-downloads what already landed.
$runtime volume create astroos-pacman-cache >/dev/null 2>&1 || true

# --ulimit: pacstrap verifies ~2000 signatures in one transaction; low fd
# limits break gpgme mid-run.
# --pids-limit=-1: podman caps a container at 2048 pids by default (docker
# doesn't). pacstrap's signature pass forks ~2 short-lived gpg processes per
# package; at ~990 of ~1900 packages the cgroup cap is hit, forks fail, and
# libalpm misreports every remaining package as "invalid or corrupted (PGP
# signature)". Survivor count was exactly 990 on every failed run.
# -t: gpg also wants a tty for some verifications ("GPGME error:
# Inappropriate ioctl for device").
$runtime run --rm --privileged -t \
  --pids-limit=-1 \
  --ulimit nofile=1048576:1048576 \
  -e BASE_REPO="$BASE_REPO" -e BASE_COMMIT="$BASE_COMMIT" \
  -e ASTROOS_FAST="${ASTROOS_FAST:-0}" \
  -v "$repo":/build -w /build \
  -v astroos-pacman-cache:/var/cache/pacman/pkg \
  "$BUILDER_IMAGE" bash /build/astroos/scripts/container-build.sh

echo ">> Emitting reproducibility artifacts..."
cd "$outdir"
iso=$(ls -1t *.iso 2>/dev/null | head -1 || true)
if [[ -n "${iso:-}" ]]; then
  sha256sum "$iso" > "sha256sums.txt"
  iso_bytes=$(stat -c%s "$iso" 2>/dev/null || stat -f%z "$iso")
  {
    echo "iso=$iso"
    echo "iso_bytes=$iso_bytes"
    echo "builder_image=$BUILDER_IMAGE"
    echo "base_repo=$BASE_REPO"
    echo "base_commit=$BASE_COMMIT"
    echo "astroos_commit=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"
  } > "build-metadata.txt"
  # Size-budget gate (council R2, D2): fail the build if the ISO regresses
  # past the budget. Post-diet expectation is ~6.5 GiB; budget default 7.
  budget_gib="${ASTROOS_SIZE_BUDGET_GIB:-7}"
  if (( iso_bytes > budget_gib * 1024 * 1024 * 1024 )); then
    echo "!! ISO is $((iso_bytes / 1024 / 1024 / 1024)) GiB — over the ${budget_gib} GiB budget (ASTROOS_SIZE_BUDGET_GIB to override)." >&2
    exit 1
  fi
  # The container writes as root; hand the artifacts back to the invoking
  # user so the (unprivileged) smoke test can write its log next to them.
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER" "$outdir" || true
  fi
  echo ">> Done: $outdir/$iso ($((iso_bytes / 1024 / 1024)) MiB, budget ${budget_gib} GiB)"
else
  echo "!! No ISO produced — check build output above." >&2
  exit 1
fi
