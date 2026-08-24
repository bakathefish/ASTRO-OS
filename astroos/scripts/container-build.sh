#!/usr/bin/env bash
# Runs INSIDE the builder container (archlinux:base-devel). Invoked by
# build-iso.sh with BASE_REPO and BASE_COMMIT in the environment.
# Flow: deps -> keyring -> clone pinned CachyOS-Live-ISO -> apply AstroOS
# delta -> run THEIR buildiso.sh -> collect artifacts to /build/out.
set -euo pipefail

: "${BASE_REPO:?}" "${BASE_COMMIT:?}"

ulimit -n 1048576 || true
echo ">> nofile limit: $(ulimit -n)"

# The image default mirror throttles big transactions; pin geo + fallbacks.
printf '%s\n' \
  'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' \
  'Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch' \
  'Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch' \
  > /etc/pacman.d/mirrorlist

pacman -Syu --noconfirm --needed base-devel archiso mkinitcpio-archiso git \
  squashfs-tools grub syslinux

# Keyring: Arch packager keys + the CachyOS signing key (the base profile's
# pacman.conf enables [cachyos] with SigLevel Required).
pacman-key --init
pacman-key --populate archlinux
pacman-key --recv-keys F3B607488DB35A47 --keyserver hkps://keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47

# Base: pinned CachyOS-Live-ISO checkout (fresh each build).
base=/build/work/base
rm -rf "$base"
mkdir -p /build/work /build/out
git clone --quiet "$BASE_REPO" "$base"
git -C "$base" checkout --quiet "$BASE_COMMIT"
echo ">> base: CachyOS-Live-ISO @ $(git -C "$base" rev-parse --short HEAD)"

prof="$base/archiso"

# --- AstroOS delta 1: packages -------------------------------------------
# Append our additions to the desktop list (their prepare_profile copies
# packages_desktop.x86_64 -> packages.x86_64), deduped against the base set.
grep -vE '^\s*(#|$)' /build/astroos/astroos-additions.x86_64 | sort -u > /tmp/astro.add
grep -vE '^\s*(#|$)' "$prof/packages_desktop.x86_64" | sort -u > /tmp/astro.base
{
  echo ''
  echo '# --- AstroOS additions (astroos/astroos-additions.x86_64) ---'
  comm -23 /tmp/astro.add /tmp/astro.base
} >> "$prof/packages_desktop.x86_64"
echo ">> package list: $(grep -cvE '^\s*(#|$)' "$prof/packages_desktop.x86_64") total ($(comm -23 /tmp/astro.add /tmp/astro.base | wc -l) AstroOS additions)"

# --- AstroOS delta 2: airootfs overlay -----------------------------------
cp -a /build/astroos/overlay/airootfs/. "$prof/airootfs/"

# --- AstroOS delta 3: identity -------------------------------------------
sed -i 's/^iso_name=.*/iso_name="astroos"/' "$prof/profiledef.sh"
sed -i 's/^iso_label=.*/iso_label="ASTROOS$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%y%m)"/' "$prof/profiledef.sh"
sed -i 's|^iso_publisher=.*|iso_publisher="AstroOS <https://github.com/bakathefish>"|' "$prof/profiledef.sh"

# --- Their build, unchanged ----------------------------------------------
cd "$base"
./buildiso.sh -p desktop

# --- Collect artifacts ----------------------------------------------------
iso=$(find "$base/out" -name '*.iso' -printf '%f\n' | head -1)
[[ -n "$iso" ]] || { echo "!! No ISO produced" >&2; exit 1; }
mv "$(find "$base/out" -name '*.iso' | head -1)" /build/out/
cp "$prof/packages_desktop.x86_64" /build/out/manifest.pkglist
echo ">> ISO: /build/out/$iso"
