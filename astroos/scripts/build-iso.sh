#!/usr/bin/env bash
# Build the AstroOS ISO: pinned CachyOS-Live-ISO base + AstroOS delta,
# inside a container (host needs only docker/podman, not Arch).
# Owner directive 7a / ledger R1.2: lift, don't rebuild. We configure and
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
  -e ASTROOS_WITH_AUR_REPO="${ASTROOS_WITH_AUR_REPO:-0}" \
  -e ASTROOS_WITH_BLACKARCH="${ASTROOS_WITH_BLACKARCH:-0}" \
  -e ASTROOS_MIN_ADDITIONS="${ASTROOS_MIN_ADDITIONS:-80}" \
  -e ASTROOS_ALLOW_UNBRANDED="${ASTROOS_ALLOW_UNBRANDED:-0}" \
  -e ASTROOS_COMMIT="${ASTROOS_COMMIT:-}" \
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
    echo "astroos_commit=${ASTROOS_COMMIT:-$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)}"
    echo "with_aur_repo=${ASTROOS_WITH_AUR_REPO:-0}"
    echo "with_blackarch=${ASTROOS_WITH_BLACKARCH:-0}"
    echo "fast=${ASTROOS_FAST:-0}"
  } > "build-metadata.txt"
  # Size-budget gate (council R2 D2, re-based in R4.1): the release must fit
  # an 8 GB USB stick (7629 MiB usable), so the default budget is 7600 MiB.
  # The round 7 GiB of the diet era rejected the 7428 MiB research ISO for no
  # physical reason. ASTROOS_SIZE_BUDGET_GIB (integer) still overrides.
  budget_mib="${ASTROOS_SIZE_BUDGET_MIB:-7600}"
  [[ -n "${ASTROOS_SIZE_BUDGET_GIB:-}" ]] && budget_mib=$(( ASTROOS_SIZE_BUDGET_GIB * 1024 ))
  if (( iso_bytes > budget_mib * 1024 * 1024 )); then
    echo "!! ISO is $((iso_bytes / 1024 / 1024)) MiB, over the ${budget_mib} MiB budget (ASTROOS_SIZE_BUDGET_MIB to override)." >&2
    exit 1
  fi
  # The container writes as root; hand the artifacts back to the invoking
  # user so the (unprivileged) smoke test can write its log next to them.
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER" "$outdir" || true
  fi
  echo ">> Done: $outdir/$iso ($((iso_bytes / 1024 / 1024)) MiB, budget ${budget_mib} MiB)"
else
  echo "!! No ISO produced. Check build output above." >&2
  exit 1
fi
