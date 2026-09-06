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

# Keyring: Arch packager keys only. [cachyos] is deleted from all three pacman
# configurations (delta 0), so nothing in the build resolves to a CachyOS
# binary and the CachyOS signing key has nothing left to verify. The one
# non-Arch repo that remains, [astroos], brings its own key through
# pacman-key --populate (delta 2c).
pacman-key --init
pacman-key --populate archlinux
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

# --- AstroOS delta 0: no [cachyos] repository -----------------------------
# AstroOS ships none of CachyOS's binaries: every package the base took from
# [cachyos] is rebuilt under an AstroOS name in the signed [astroos] repo
# (delta 2c), so the section goes from all three configurations. The build
# conf carries it as a hardcoded mirror.cachyos.org Server, the two airootfs
# confs as SigLevel Optional TrustAll plus a cachyos-mirrorlist Include.
# awk, not sed: the body is 1-2 lines today, and this drops it without
# counting, stopping at the next section header or at the blank line that
# ends this one, whichever comes first. The ^\[cachyos prefix also catches
# [cachyos-v3] and friends should the base ever grow them.
for c in "${pconfs[@]}"; do
  [[ -f "$c" ]] || { echo "!! missing pacman configuration $c" >&2; exit 1; }
  awk '
    /^\[cachyos/             { skip = 1; next }
    skip && /^\[/            { skip = 0 }
    skip && /^[[:space:]]*$/ { skip = 0; next }
    skip                     { next }
                             { print }
  ' "$c" > /tmp/pacman.conf.nocachy
  mv /tmp/pacman.conf.nocachy "$c"
done
if hits=$(grep -nE '^\[cachyos' "${pconfs[@]}"); then
  echo "!! a [cachyos] section survived the removal:" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo ">> [cachyos] removed from the build, live and installed pacman.conf"

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
# list is broken (e.g. gen-packages emitting garbage); a base-only ISO would
# still pass the boot gate, so fail here instead of shipping a no-op AstroOS.
min_adds="${ASTROOS_MIN_ADDITIONS:-80}"
if (( net_adds < min_adds )); then
  echo "!! Only $net_adds net additions (< $min_adds floor). Additions list looks broken. Aborting." >&2
  exit 1
fi
# Every CachyOS name the base list carries, and what AstroOS installs instead.
# The whole substitution lives in this one table; "-" in the second column
# removes the line rather than renaming it. The kernels, hooks, settings,
# mirrorlists, chroot helper, hardware detection and installer are rebuilt
# under our names in [astroos] (delta 2c). cachyos-keyring goes because
# astroos-keyring is already installed from there and holds the only repo key
# the ISO trusts; cachyos-hello (survey row 4) and the CachyOS TUI installer
# (row 26) have no package replacement (plasma-welcome +
# astroos-install.desktop, and Calamares, cover them) and nothing on the ISO
# depends on either. Every name below is in the base list today, so a
# substitution that does not apply means the base moved, and a silently
# skipped one would either ship an upstream package or drop a kernel.
pkglist="$prof/packages_desktop.x86_64"
renamed=0 dropped=0
while read -r old new; do
  [[ -n "$old" ]] || continue
  grep -qx "$old" "$pkglist" || { echo "!! expected $old in the base package list (base moved?)" >&2; exit 1; }
  if [[ "$new" == "-" ]]; then
    sed -i "/^$old\$/d" "$pkglist"
    dropped=$((dropped + 1))
  else
    sed -i "s/^$old\$/$new/" "$pkglist"
    grep -qx "$new" "$pkglist" || { echo "!! $old -> $new did not land in $pkglist" >&2; exit 1; }
    renamed=$((renamed + 1))
  fi
  if grep -qx "$old" "$pkglist"; then
    echo "!! $old survives in $pkglist after its substitution" >&2
    exit 1
  fi
done <<'PKGMAP'
linux-cachyos                  linux-astroos
linux-cachyos-lts              linux-astroos-lts
linux-cachyos-nvidia-open      linux-astroos-nvidia-open
linux-cachyos-zfs              linux-astroos-zfs
linux-cachyos-lts-nvidia-open  linux-astroos-lts-nvidia-open
linux-cachyos-lts-zfs          linux-astroos-lts-zfs
cachyos-hooks                  astroos-hooks
cachyos-settings               astroos-settings
cachyos-kde-settings           astroos-kde-settings
cachyos-fish-config            astroos-fish-config
cachyos-rate-mirrors           astroos-rate-mirrors
cachy-chroot                   astroos-chroot
cachyos-mirrorlist             astroos-mirrorlist
cachyos-v3-mirrorlist          astroos-v3-mirrorlist
cachyos-v4-mirrorlist          astroos-v4-mirrorlist
cachyos-calamares-next         astroos-calamares-installer
chwd                           astroos-chwd
cachyos-keyring                -
cachyos-hello                  -
cachyos-cli-installer-new      -
PKGMAP
echo ">> base list: $renamed CachyOS names renamed to AstroOS, $dropped removed"

# --- AstroOS delta 2: airootfs overlay (live-only files) ------------------
cp -a /build/astroos/overlay/airootfs/. "$prof/airootfs/"
# the profile's own release file (survey row 25): nothing reads it and the
# identity hook removes it from installed systems, so the live ISO drops it too
rm -f "$prof/airootfs/etc/cachyos-release"
# The Arch mirrorlist the live medium ships puts two CachyOS CDN hosts at the
# top, so every official Arch package on the ISO is currently fetched through
# CachyOS infrastructure. Drop those Server lines and the comment that sells
# them; the pkgbuild.com geo mirror below them becomes the first entry.
ml="$prof/airootfs/etc/pacman.d/mirrorlist"
[[ -f "$ml" ]] || { echo "!! missing $ml (base moved?)" >&2; exit 1; }
grep -qiE '^[[:space:]]*Server[[:space:]]*=.*cachyos\.org' "$ml" \
  || { echo "!! expected CachyOS CDN Server lines in the live mirrorlist (base moved?)" >&2; exit 1; }
sed -i -E '/^[[:space:]]*#.*[Cc]achy/d; /^[[:space:]]*Server[[:space:]]*=.*cachyos\.org/d' "$ml"
grep -qiE '^[[:space:]]*Server[[:space:]]*=' "$ml" \
  || { echo "!! the live mirrorlist has no Server line left after dropping the CachyOS CDN" >&2; exit 1; }
# The live KWin keyboard hook triggers on the settings package, which is ours
# now. Its "remove from airootfs!" first line is what deletes it at the end of
# pacstrap (zzzz99 hook, by content), so renaming the file is safe.
hooks="$prof/airootfs/etc/pacman.d/hooks"
[[ -f "$hooks/90-cachyos-live-kwin-keyboard.hook" ]] \
  || { echo "!! missing $hooks/90-cachyos-live-kwin-keyboard.hook (base moved?)" >&2; exit 1; }
sed -i 's/^Target = cachyos-kde-settings$/Target = astroos-kde-settings/' "$hooks/90-cachyos-live-kwin-keyboard.hook"
mv "$hooks/90-cachyos-live-kwin-keyboard.hook" "$hooks/90-astroos-live-kwin-keyboard.hook"
grep -qx 'Target = astroos-kde-settings' "$hooks/90-astroos-live-kwin-keyboard.hook" \
  || { echo "!! the live KWin keyboard hook still triggers on cachyos-kde-settings" >&2; exit 1; }
# --- AstroOS delta 2b: bootloader branding (profile-level, not airootfs) ---
br=/build/astroos/branding/out
# Bootloader splashes + menu titles. The efiboot loader entries carry titles
# too and the branding sed never reached them: they are dead weight under
# bootmodes=('bios.syslinux' 'uefi.grub'), but a CachyOS title on our medium
# is still a leak.
install -m644 "$br/splash-1920.png" "$base/archiso/grub/splash.png"
install -m644 "$br/splash-1920.png" "$base/archiso/syslinux/splash.png"
install -m644 "$br/splash-640.png"  "$base/archiso/syslinux/splash1.png"
sed -i 's/CachyOS/AstroOS/g' "$base/archiso/grub/grub.cfg" \
  "$base/archiso/grub/loopback.cfg" "$base"/archiso/syslinux/*.cfg \
  "$base"/archiso/efiboot/loader/entries/*.conf

# --- AstroOS delta 2b-kernel: the boot files name OUR kernel --------------
# Every boot path names the kernel by filename, not by package, and the
# filename follows the package: linux-astroos installs
# /boot/vmlinuz-linux-astroos and mkarchiso copies /boot/vmlinuz-* and
# initramfs-*.img into the medium verbatim. Left alone, every menu entry
# would point at a file that does not exist, and linux.preset would build
# the live initramfs from a kernel that is not there, which fails long
# before a menu is ever drawn. The comment that used to sit here said the
# lowercase paths must never be touched; that was right while the kernel
# came from [cachyos].
efi="$base/archiso/efiboot/loader/entries"
[[ -f "$efi/02-archiso-linux-cachyos.conf" ]] \
  || { echo "!! missing $efi/02-archiso-linux-cachyos.conf (base moved?)" >&2; exit 1; }
mv "$efi/02-archiso-linux-cachyos.conf" "$efi/02-archiso-linux-astroos.conf"
kfiles=("$prof/airootfs/etc/mkinitcpio.d/linux.preset"
        "$base/archiso/grub/grub.cfg" "$base/archiso/grub/loopback.cfg"
        "$base"/archiso/syslinux/archiso_sys-linux.cfg
        "$base"/archiso/syslinux/archiso_pxe-linux.cfg
        "$efi"/*.conf)
for f in "${kfiles[@]}"; do
  [[ -f "$f" ]] || { echo "!! missing boot file $f (base moved?)" >&2; exit 1; }
done
sed -i 's/-linux-cachyos/-linux-astroos/g' "${kfiles[@]}"
if hits=$(grep -n 'linux-cachyos' "${kfiles[@]}"); then
  echo "!! a boot file still names the CachyOS kernel:" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
hits=$(find "$base/archiso/efiboot" -iname '*cachy*')
[[ -z "$hits" ]] || { echo "!! CachyOS-named file under efiboot: $hits" >&2; exit 1; }
grep -qx "ALL_kver='/boot/vmlinuz-linux-astroos-lts'" "$prof/airootfs/etc/mkinitcpio.d/linux.preset" \
  || { echo "!! linux.preset ALL_kver is not the AstroOS LTS kernel (it builds the live initramfs)" >&2; exit 1; }
echo ">> boot files point at the AstroOS kernel: ${#kfiles[@]} files rewritten"

# --- AstroOS delta 2c: [astroos] prebuilt repo (council R3, ratified; R4.1) --
# Adds the signed Azure-hosted repo to the build, the live system AND the
# installed system (pacman-more.conf), trusts the key, and installs every
# aur.list package plus every local package from prebuilt binaries. The
# section stays appended AFTER the Arch repos (review D-D). It carries system
# packages now, not just extras, because the [cachyos] replacements land here
# (linux-astroos, astroos-settings, astroos-hooks), but every name in it is
# still AUR-only or AstroOS-only: ordering shadows nothing either way, and a
# name that later reaches [extra] is then taken from there.
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
  # pacstrap. A missing/extra name means repo and tree diverged: hard fail.
  mapfile -t aur_scope < <(tr -d '\r' < /build/astroos/meta/aur.list | grep -vE '^\s*(#|$)' | awk '{print $1}')
  # A PKGBUILD that produces more than one pkgname lists the extra names in
  # pkgs/<name>/splits: one linux-astroos build yields the base package,
  # headers, the ZFS module and the open NVIDIA module, and the db carries
  # all four, so the scope has to as well or D4 rejects a correct repo. Same
  # parse as build-aur-repo.sh's local_splits; the two must not disagree.
  mapfile -t local_scope < <(for d in /build/astroos/pkgs/*/; do
    [[ -f "$d/PKGBUILD" ]] || continue
    basename "$d"
    [[ -f "$d/splits" ]] && tr -d '\r' < "$d/splits" | grep -vE '^\s*(#|$)' | awk '{print $1}'
  done)
  mapfile -t scope < <(printf '%s\n' "${aur_scope[@]}" "${local_scope[@]}" | sort -u)
  # What the ISO installs is a narrower set than what the db carries: the AUR
  # scope plus the build units, not their splits. The split names the medium
  # needs (linux-astroos-zfs, -nvidia-open and the LTS pair) already reach the
  # list through the rename table above, because upstream's list named them.
  # The headers packages do not, and must not: they are in the repo for DKMS
  # on installed systems, and adding two of them to a medium that sits under
  # 200 MiB from its size gate would trade real margin for nothing a live
  # session uses.
  mapfile -t local_units < <(for d in /build/astroos/pkgs/*/; do [[ -f "$d/PKGBUILD" ]] && basename "$d"; done)
  mapfile -t install_scope < <(printf '%s\n' "${aur_scope[@]}" "${local_units[@]}" | sort -u)
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
  echo ">> [astroos] repo check OK: ${#db_names[@]} packages match aur.list (${#aur_scope[@]}) + pkgs/ (${#local_scope[@]} names, splits included)"
  # SigLevel staging per R3 D2/Q4: Required DatabaseOptional for publish
  # cycle 1 only.
  repo_section=$(printf '\n[astroos]\nSigLevel = Required DatabaseOptional\nServer = %s\n' "$repo_url")
  for c in "${pconfs[@]}"; do
    [[ -f "$c" ]] || { echo "!! missing pacman configuration $c" >&2; exit 1; }
    grep -q '^\[astroos\]' "$c" || printf '%s\n' "$repo_section" >> "$c"
  done
  printf '%s\n' "${install_scope[@]}" >> "$prof/packages_desktop.x86_64"
  echo ">> [astroos] enabled in build, live and installed pacman.conf: +${#install_scope[@]} prebuilt packages on the medium (${#scope[@]} in the db)"
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
# symlink blobs that a Windows worktree cannot materialize; a checkout that
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
[[ ! -e "$prof/airootfs/etc/cachyos-release" ]] \
  || { echo "!! overlay preflight: etc/cachyos-release still in airootfs" >&2; preflight_fail=1; }
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

# --- The gate: no CachyOS name reaches pacstrap or a shipped pacman.conf --
# Every edit above is a targeted substitution, so this is the check that
# proves the set of targets was complete: the list pacstrap installs from,
# plus the three configurations that decide where packages come from on the
# builder, on the live system and on the installed system. A hit here means
# a CachyOS package would be installed or a CachyOS repo shipped.
if hits=$(grep -rniE 'cachy' "$prof/packages_desktop.x86_64" "${pconfs[@]}"); then
  echo "!! CachyOS survives the AstroOS delta:" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo ">> no cachy string in the package list or in any of the three pacman configurations"
# The same question asked of the whole profile, with a named allowlist so a
# leftover cannot hide behind a blanket exclusion:
#   GRUB ids: default= has to match an --id, and CACHYOS_VERSION is the
#     variable their change_grub_version sed writes into. Both are internal
#     to GRUB, neither is rendered (survey section 7 keeps them).
#   removeun, removeun-online, calamares-online.sh: live-only scripts the
#     branding lane replaces through the overlay, not here.
#   airootfs/usr/share: astroos-calamares' apply.sh carries "cachyos" as a
#     sed pattern, so the string there is the tool, not a leak.
prof_allow='/airootfs/usr/share/|/airootfs/usr/local/bin/(removeun|removeun-online|calamares-online\.sh):|/grub/(grub|loopback)\.cfg:[0-9]+:.*(CACHYOS_VERSION|default=cachyos|--id .cachyos)'
prof_hits=$(grep -rIin cachy "$prof" | grep -vE "$prof_allow") || true
if [[ -n "$prof_hits" ]]; then
  echo "!! CachyOS survives elsewhere in the profile:" >&2
  printf '%s\n' "$prof_hits" >&2
  exit 1
fi
echo ">> profile clean: the only cachy strings left are the GRUB ids, the overlay-owned live scripts and usr/share sed patterns"

# --- Their build (four one-line patches) ---------------------------------
# Their buildiso.sh traps EXIT itself with an error message, so EVERY run,
# success included, ends with "==> ERROR: An unknown error has occurred."
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
# prepare_profile also curls cachyos-mirrorlist from CachyOS-PKGBUILDS into
# airootfs at build time, which would recreate the file delta 2 just removed.
# The function definition stays (dead); only the call is neutralised.
sed -i 's|^    fetch_cachyos_mirrorlist$|    : # AstroOS: the mirrorlist ships in the astroos-mirrorlist package|' "$base/util-iso.sh"
grep -q '^    fetch_cachyos_mirrorlist$' "$base/util-iso.sh" && { echo "!! fetch_cachyos_mirrorlist call still present (util-iso.sh changed?)" >&2; exit 1; }
# and it masks the mirror-ranking timer by unit name; ours is astroos-.
sed -i 's|/etc/systemd/system/cachyos-rate-mirrors.timer|/etc/systemd/system/astroos-rate-mirrors.timer|' "$base/util-iso.sh"
grep -q 'astroos-rate-mirrors.timer' "$base/util-iso.sh" || { echo "!! rate-mirrors timer mask not retargeted (util-iso.sh changed?)" >&2; exit 1; }
cd "$base"
./buildiso.sh -p desktop

# --- Collect artifacts ----------------------------------------------------
iso=$(find "$base/out" -name '*.iso' -printf '%f\n' | head -1)
[[ -n "$iso" ]] || { echo "!! No ISO produced" >&2; exit 1; }
mv "$(find "$base/out" -name '*.iso' | head -1)" /build/out/
cp "$prof/packages_desktop.x86_64" /build/out/manifest.pkglist
echo ">> ISO: /build/out/$iso"
