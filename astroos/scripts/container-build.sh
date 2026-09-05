#!/usr/bin/env bash
# Runs INSIDE the builder container (archlinux:base-devel). Invoked by
# build-iso.sh with BASE_REPO and BASE_COMMIT in the environment.
# Flow: deps -> keyring -> clone pinned CachyOS-Live-ISO -> apply AstroOS
# delta -> run THEIR buildiso.sh -> collect artifacts to /build/out.
#
# Since R4.1 (2026-09-05) the AstroOS identity is delivered by PACKAGES from
# the signed [astroos] repo (astroos-keyring, astroos-branding, astroos-tools,
# astroos-calamares, astroos-zenbook-duo), because the CachyOS installer is an
# online pacstrap installer and only packages reach installed systems
# (.planning/R4_BRANDING_SURVEY.md §0). The airootfs overlay carries live-only
# files. The repo is therefore a hard input of a branded ISO: building without
# it needs ASTROOS_ALLOW_UNBRANDED=1 (pipeline debugging only).
set -euo pipefail

: "${BASE_REPO:?}" "${BASE_COMMIT:?}"
echo ">> flags: ASTROOS_WITH_AUR_REPO=${ASTROOS_WITH_AUR_REPO:-0} ASTROOS_WITH_BLACKARCH=${ASTROOS_WITH_BLACKARCH:-0} ASTROOS_FAST=${ASTROOS_FAST:-0} ASTROOS_MIN_ADDITIONS=${ASTROOS_MIN_ADDITIONS:-80} ASTROOS_ALLOW_UNBRANDED=${ASTROOS_ALLOW_UNBRANDED:-0} ASTROOS_COMMIT=${ASTROOS_COMMIT:-unknown}"
if [[ "${ASTROOS_WITH_AUR_REPO:-0}" != "1" && "${ASTROOS_ALLOW_UNBRANDED:-0}" != "1" ]]; then
  echo "!! ASTROOS_WITH_AUR_REPO=1 is required: identity, tools and installer config are packages in [astroos] (set ASTROOS_ALLOW_UNBRANDED=1 to build a pipeline-debug ISO)" >&2
  exit 1
fi

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
# Keyservers flake ("keyserver receive failed: No data"), so: retry across
# transports, then fall back to extracting the key from the cachyos-keyring
# package over https from their mirror.
import_cachyos_key() {
  local ks _
  for ks in hkps://keyserver.ubuntu.com hkp://keyserver.ubuntu.com:80; do
    for _ in 1 2 3; do
      pacman-key --recv-keys F3B607488DB35A47 --keyserver "$ks" && return 0
      sleep 5
    done
  done
  echo ">> Keyservers unreachable; extracting key from cachyos-keyring package"
  local idx pkg
  idx=$(curl -sL https://mirror.cachyos.org/repo/x86_64/cachyos/)
  pkg=$(printf '%s' "$idx" | grep -oE 'cachyos-keyring-[0-9][^"<>]*\.pkg\.tar\.zst' | head -1)
  [[ -n "$pkg" ]] || { echo "!! cachyos-keyring package not found in mirror index" >&2; return 1; }
  curl -sLo /tmp/cachyos-keyring.zst "https://mirror.cachyos.org/repo/x86_64/cachyos/$pkg"
  bsdtar -xf /tmp/cachyos-keyring.zst -C /tmp 'usr/share/pacman/keyrings/*'
  pacman-key --add /tmp/usr/share/pacman/keyrings/cachyos.gpg
}
import_cachyos_key
pacman-key --lsign-key F3B607488DB35A47
# Mass verification in a container dies mid-transaction with
# "GPGME error: Inappropriate ioctl for device" when gpg decides it wants a
# tty. Belt (no-tty here) and suspenders (-t on the podman run).
printf 'no-tty\n' >> /etc/pacman.d/gnupg/gpg.conf

# Base: pinned CachyOS-Live-ISO checkout (fresh each build).
base=/build/work/base
rm -rf "$base"
mkdir -p /build/work /build/out
git clone --quiet "$BASE_REPO" "$base"
git -C "$base" checkout --quiet "$BASE_COMMIT"
echo ">> base: CachyOS-Live-ISO @ $(git -C "$base" rev-parse --short HEAD)"

prof="$base/archiso"
# the three pacman configurations that matter: the build's (pacstrap), the
# live system's, and pacman-more.conf, which the installer copies to the
# installed system as ITS pacman.conf (survey §0: the only overlay file that
# reaches disk)
pconfs=("$prof/pacman.conf" "$prof/airootfs/etc/pacman.conf" "$prof/airootfs/etc/pacman-more.conf")

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
net_adds=$(comm -23 /tmp/astro.add /tmp/astro.base | wc -l)
echo ">> package list: $(grep -cvE '^\s*(#|$)' "$prof/packages_desktop.x86_64") total ($net_adds AstroOS additions)"
# Council R2 (B2): a suspiciously small additions count means the generated
# list is broken (e.g. gen-packages emitting garbage) — a base-only ISO would
# still pass the boot gate, so fail here instead of shipping a no-op AstroOS.
min_adds="${ASTROOS_MIN_ADDITIONS:-80}"
if (( net_adds < min_adds )); then
  echo "!! Only $net_adds net additions (< $min_adds floor) — additions list looks broken. Aborting." >&2
  exit 1
fi
# CachyOS-only apps that cannot be rebranded by configuration (survey rows 4,
# 26): the GTK welcome app (plasma-welcome + astroos-install.desktop replace
# it) and the CachyOS TUI installer. Nothing on the ISO depends on either.
for p in cachyos-hello cachyos-cli-installer-new; do
  grep -qx "$p" "$prof/packages_desktop.x86_64" || { echo "!! expected $p in the base package list (base moved?)" >&2; exit 1; }
  sed -i "/^$p\$/d" "$prof/packages_desktop.x86_64"
done
echo ">> removed from the base list: cachyos-hello cachyos-cli-installer-new"

# --- AstroOS delta 2: airootfs overlay (live-only files) ------------------
cp -a /build/astroos/overlay/airootfs/. "$prof/airootfs/"
# --- AstroOS delta 2b: bootloader branding (profile-level, not airootfs) ---
br=/build/astroos/branding/out
# Bootloader splashes + menu titles. Only the capitalized brand string is
# rewritten: lowercase "cachyos" appears in kernel and package file paths
# (vmlinuz-linux-cachyos) and must never be touched.
install -m644 "$br/splash-1920.png" "$base/archiso/grub/splash.png"
install -m644 "$br/splash-1920.png" "$base/archiso/syslinux/splash.png"
install -m644 "$br/splash-640.png"  "$base/archiso/syslinux/splash1.png"
sed -i 's/CachyOS/AstroOS/g' "$base/archiso/grub/grub.cfg" \
  "$base/archiso/grub/loopback.cfg" "$base"/archiso/syslinux/*.cfg

# --- AstroOS delta 2c: [astroos] prebuilt repo (council R3, ratified; R4.1) --
# Adds the signed Azure-hosted repo to the build, the live system AND the
# installed system (pacman-more.conf), trusts the key, and installs every
# aur.list package plus every local package from prebuilt binaries. The
# section is appended AFTER the Arch repos (review D-D): every name in it is
# AUR-only or AstroOS-only, so nothing is shadowed either way, and a name
# that later reaches [extra] is then taken from there.
if [[ "${ASTROOS_WITH_AUR_REPO:-0}" == "1" ]]; then
  akr=/build/astroos/pkgs/astroos-keyring/files/usr/share/pacman/keyrings
  fpr_expect=$(tr -d ' \r\n' < /build/astroos/branding/REPO_FINGERPRINT)
  # Q2 fingerprint assertion: shipped keyring must be the key the repo db is
  # signed with, and the trust file must grant it ownertrust 4.
  fpr_ship=$(gpg --show-keys --with-colons "$akr/astroos.gpg" | awk -F: '/^fpr/{print $10; exit}')
  [[ "$fpr_ship" == "$fpr_expect" ]] \
    || { echo "!! astroos keyring fingerprint mismatch: shipped=$fpr_ship expected=$fpr_expect" >&2; exit 1; }
  [[ "$(tr -d ' \r\n' < "$akr/astroos-trusted")" == "${fpr_expect}:4:" ]] \
    || { echo "!! astroos-trusted must be '${fpr_expect}:4:' (is: $(cat "$akr/astroos-trusted"))" >&2; exit 1; }
  # build-time trust through the same populate path clients use
  install -m644 "$akr/astroos.gpg" "$akr/astroos-trusted" "$akr/astroos-revoked" /usr/share/pacman/keyrings/
  pacman-key --populate astroos
  repo_url='https://astroosrepo.blob.core.windows.net/repo/astroos/$arch'
  # D4 client-side machine check: repo db name set == aur.list ∪ pkgs/, BEFORE
  # pacstrap. A missing/extra name means repo and tree diverged — hard fail.
  mapfile -t aur_scope < <(tr -d '\r' < /build/astroos/meta/aur.list | grep -vE '^\s*(#|$)' | awk '{print $1}')
  mapfile -t local_scope < <(for d in /build/astroos/pkgs/*/; do [[ -f "$d/PKGBUILD" ]] && basename "$d"; done)
  mapfile -t scope < <(printf '%s\n' "${aur_scope[@]}" "${local_scope[@]}" | sort -u)
  curl -sfL "https://astroosrepo.blob.core.windows.net/repo/astroos/x86_64/astroos.db.tar.zst" -o /tmp/astroos.db.tar.zst \
    || { echo "!! [astroos] repo db unreachable" >&2; exit 1; }
  # every db entry is a <name-ver-rel>/desc member; keying on "desc" does not
  # depend on the tarball carrying explicit directory entries
  mapfile -t db_names < <(bsdtar -tf /tmp/astroos.db.tar.zst | awk -F/ '$2=="desc"{print $1}' | sed 's/-[^-]*-[^-]*$//' | sort -u)
  if [[ "$(printf '%s\n' "${scope[@]}")" != "$(printf '%s\n' "${db_names[@]}")" ]]; then
    echo "!! [astroos] repo/tree scope mismatch (D4):" >&2
    diff <(printf '%s\n' "${scope[@]}") <(printf '%s\n' "${db_names[@]}") >&2 || true
    exit 1
  fi
  echo ">> [astroos] repo check OK: ${#db_names[@]} packages match aur.list (${#aur_scope[@]}) + pkgs/ (${#local_scope[@]})"
  # SigLevel staging per R3 D2/Q4: Required DatabaseOptional for publish
  # cycle 1 only.
  repo_section=$(printf '\n[astroos]\nSigLevel = Required DatabaseOptional\nServer = %s\n' "$repo_url")
  for c in "${pconfs[@]}"; do
    [[ -f "$c" ]] || { echo "!! missing pacman configuration $c" >&2; exit 1; }
    grep -q '^\[astroos\]' "$c" || printf '%s\n' "$repo_section" >> "$c"
  done
  printf '%s\n' "${scope[@]}" >> "$prof/packages_desktop.x86_64"
  echo ">> [astroos] enabled in build, live and installed pacman.conf: +${#scope[@]} prebuilt packages"
fi

# --- AstroOS delta 2d: [blackarch] repo (spec §3a Phase 2, council R4) ------
# Gated. Trust anchor: the keyring tarball from blackarch.org over TLS, pinned
# by version + sha256 in astroos/blackarch-keyring.lock (same pattern as
# base.lock): an upstream change hard-fails the build until the pin is bumped
# deliberately. The repo is appended AFTER the Arch repos and after [astroos]
# in every pacman.conf (build, live, installed), so BlackArch never shadows an
# official or AstroOS package.
if [[ "${ASTROOS_WITH_BLACKARCH:-0}" == "1" ]]; then
  # shellcheck source=../blackarch-keyring.lock
  source /build/astroos/blackarch-keyring.lock
  : "${BA_KEYRING_VERSION:?}" "${BA_KEYRING_SHA256:?}"
  bak=/tmp/blackarch-keyring; rm -rf "$bak"; mkdir -p "$bak"
  # blackarch.org keeps only the current tarball at keyring/ and moves
  # superseded ones to keyring/old/ (review m11): try both before failing.
  ba_tar="blackarch-keyring-${BA_KEYRING_VERSION}.tar.gz"
  curl -sfL "https://www.blackarch.org/keyring/$ba_tar" -o "$bak/keyring.tar.gz" \
    || curl -sfL "https://www.blackarch.org/keyring/old/$ba_tar" -o "$bak/keyring.tar.gz" \
    || { echo "!! blackarch keyring tarball ${BA_KEYRING_VERSION} unreachable at keyring/ and keyring/old/ (superseded upstream? bump astroos/blackarch-keyring.lock)" >&2; exit 1; }
  echo "${BA_KEYRING_SHA256}  $bak/keyring.tar.gz" | sha256sum -c --quiet \
    || { echo "!! blackarch keyring tarball sha256 != astroos/blackarch-keyring.lock (upstream changed; review + bump the pin)" >&2; exit 1; }
  tar xzf "$bak/keyring.tar.gz" -C "$bak" --strip-components=1
  install -Dm644 "$bak/blackarch.gpg"     /usr/share/pacman/keyrings/blackarch.gpg
  install -Dm644 "$bak/blackarch-trusted" /usr/share/pacman/keyrings/blackarch-trusted
  install -Dm644 "$bak/blackarch-revoked" /usr/share/pacman/keyrings/blackarch-revoked
  pacman-key --populate blackarch
  # build-time mirror; the shipped systems get the same path from the
  # blackarch-mirrorlist package (meta/blackarch.list)
  echo 'Server = https://blackarch.org/blackarch/$repo/os/$arch' > /etc/pacman.d/blackarch-mirrorlist
  ba_section=$(printf '\n[blackarch]\nSigLevel = Required DatabaseOptional\nInclude = /etc/pacman.d/blackarch-mirrorlist\n')
  for c in "${pconfs[@]}"; do
    grep -q '^\[blackarch\]' "$c" || printf '%s\n' "$ba_section" >> "$c"
  done
  mapfile -t ba_pkgs < <(tr -d '\r' < /build/astroos/meta/blackarch.list | grep -vE '^\s*(#|$)' | awk '{print $1}')
  (( ${#ba_pkgs[@]} > 0 )) || { echo "!! meta/blackarch.list is empty" >&2; exit 1; }
  printf '%s\n' "${ba_pkgs[@]}" >> "$prof/packages_desktop.x86_64"
  echo ">> [blackarch] enabled: keyring ${BA_KEYRING_VERSION} populated, repo appended after the Arch repos, +${#ba_pkgs[@]} packages (${ba_pkgs[*]})"
fi

# Overlay integrity preflight (council R2, D4). The mask units live in git as
# symlink blobs that a Windows worktree cannot materialize — a checkout that
# silently loses them still builds and boots, so assert them here.
preflight_fail=0
for u in systemd-networkd-wait-online.service systemd-time-wait-sync.service; do
  p="$prof/airootfs/etc/systemd/system/$u"
  [[ -L "$p" && "$(readlink "$p")" == "/dev/null" ]] \
    || { echo "!! overlay preflight: $u is not a /dev/null mask symlink" >&2; preflight_fail=1; }
done
for f in etc/hostname etc/os-release etc/issue etc/plymouth/plymouthd.conf \
         etc/skel/.config/plasma-welcomerc \
         usr/share/applications/astroos-install.desktop \
         usr/local/bin/calamares-online.sh usr/local/bin/astroos-smoke-report \
         etc/systemd/system/astroos-smoke.service; do
  [[ -e "$prof/airootfs/$f" ]] \
    || { echo "!! overlay preflight: missing $f" >&2; preflight_fail=1; }
done
[[ "$(tr -d '\r\n' < "$prof/airootfs/etc/hostname")" == "astroos" ]] \
  || { echo "!! overlay preflight: etc/hostname is not 'astroos'" >&2; preflight_fail=1; }
# plasma-welcome resolves LiveInstaller with KService::serviceByDesktopName:
# the desktop entry NAME, no .desktop suffix (with the suffix the Welcome
# Center's install icon was empty and its click a no-op, E2E 2026-09-05).
grep -q '^LiveInstaller=astroos-install$' "$prof/airootfs/etc/skel/.config/plasma-welcomerc" \
  || { echo "!! overlay preflight: plasma-welcomerc LiveInstaller must be exactly astroos-install (no .desktop suffix)" >&2; preflight_fail=1; }
[[ -f "$prof/airootfs/usr/share/applications/astroos-install.desktop" ]] \
  || { echo "!! overlay preflight: usr/share/applications/astroos-install.desktop missing" >&2; preflight_fail=1; }
[[ -L "$prof/airootfs/etc/systemd/system/multi-user.target.wants/astroos-smoke.service" ]] \
  || { echo "!! overlay preflight: smoke unit wants-symlink missing" >&2; preflight_fail=1; }
# nothing the packages ship may be pre-placed by the overlay (pacstrap would
# refuse the file conflict): assert the moved paths stayed out
for f in etc/pacman.d/hooks/zz-astroos-identity.hook usr/share/astroos/branding/os-release \
         usr/share/pacman/keyrings/astroos.gpg usr/local/bin/astroos-doctor etc/fastfetch/config.jsonc; do
  [[ ! -e "$prof/airootfs/$f" ]] \
    || { echo "!! overlay preflight: $f is shipped by a package now; remove it from the overlay" >&2; preflight_fail=1; }
done
(( preflight_fail == 0 )) || exit 1
echo ">> overlay preflight OK"

# --- AstroOS delta 3: identity -------------------------------------------
sed -i 's/^iso_name=.*/iso_name="astroos"/' "$prof/profiledef.sh"
sed -i 's/^iso_label=.*/iso_label="ASTROOS$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%y%m)"/' "$prof/profiledef.sh"
sed -i 's|^iso_publisher=.*|iso_publisher="AstroOS <https://github.com/bakathefish>"|' "$prof/profiledef.sh"
sed -i 's|^iso_application=.*|iso_application="AstroOS Live/Rescue DVD"|' "$prof/profiledef.sh"
grep -q '^iso_application="AstroOS' "$prof/profiledef.sh" || { echo "!! iso_application sed did not apply" >&2; exit 1; }
# Exec bits inside the image are governed by profiledef file_permissions;
# register the overlay executable there (build 8 shipped doctor 0644). The
# packaged tools carry their own modes; calamares-online.sh is in the base list.
sed -i 's|^file_permissions=(|file_permissions=(\n  ["/usr/local/bin/astroos-smoke-report"]="0:0:755"|' "$prof/profiledef.sh"

# --- Iteration mode -------------------------------------------------------
# ASTROOS_FAST=1 swaps squashfs xz (slow, small; the release setting) for
# zstd (minutes instead of hours). Boot behavior is identical; release
# builds run without the flag.
if [[ "${ASTROOS_FAST:-0}" == "1" ]]; then
  echo ">> FAST build: squashfs zstd instead of xz"
  sed -i "s/^airootfs_image_tool_options=.*/airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '6' '-b' '1M')/" \
    "$prof/profiledef.sh"
fi

# --- Their build (four one-line patches) ---------------------------------
# Their buildiso.sh traps EXIT itself with an error message, so EVERY run —
# success included — ends with "==> ERROR: An unknown error has occurred."
# (ledger R2-C3). Delete only the EXIT trap; ERR/INT/TERM traps stay intact.
sed -i "/trap 'trap_exit EXIT/d" "$base/buildiso.sh"
# USER: their util-iso.sh ends with `sudo chown $USER $outFolder`; in the
# container's non-login root shell $USER is unset and the chown (after the
# ISO is fully written) errors out the whole script.
export USER=root
# Their post-build rename hardcodes the "cachyos" filename prefix in two
# places; with our iso_name=astroos the mv can't find its source.
sed -i 's|/cachyos-$(date|/astroos-$(date|' "$base/util-iso.sh"
sed -i 's|vars+=("cachyos")|vars+=("astroos")|' "$base/util-iso.sh"
# prepare_profile writes a CachyOS motd into airootfs AFTER our overlay copy
# (survey row 2); the AstroOS motd comes from astroos-branding's identity hook
# at pacstrap time, so the generator call becomes a no-op.
sed -i 's/^    generate_motd$/    : # AstroOS: motd is written by the astroos-branding identity hook/' "$base/util-iso.sh"
grep -q '^    generate_motd$' "$base/util-iso.sh" && { echo "!! generate_motd call still present (util-iso.sh changed?)" >&2; exit 1; }
cd "$base"
./buildiso.sh -p desktop

# --- Collect artifacts ----------------------------------------------------
iso=$(find "$base/out" -name '*.iso' -printf '%f\n' | head -1)
[[ -n "$iso" ]] || { echo "!! No ISO produced" >&2; exit 1; }
mv "$(find "$base/out" -name '*.iso' | head -1)" /build/out/
cp "$prof/packages_desktop.x86_64" /build/out/manifest.pkglist
echo ">> ISO: /build/out/$iso"
