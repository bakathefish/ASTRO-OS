#!/usr/bin/env bash
# AstroOS forge: the one-command release pipeline. Runs ON the build VM
# (astroos-forge) from the repo checkout; the laptop driver is
# forge-remote.sh (start VM, sync, run this, collect, deallocate).
#
#   repo     build the signed [astroos] repo: AUR scope + local packages
#            (resumable; hours)
#   publish  upload it (packages first, db last: R3 risk #2)
#   verify   prove the HOSTED repo works for a client: db + lock signatures
#            against the SHIPPED keyring through the real trust path
#            (pacman-key --populate astroos), name set == aur.list ∪ pkgs/
#            (D4), and a fresh container installing real packages with
#            SigLevel Required
#   iso      release ISO build with the repo enabled (xz squashfs)
#   gate     QEMU boot gate (five in-guest verdicts, qemu-smoke.sh)
#   audit    content audit INSIDE the artifact: identity, branding, installer
#            configuration, repo wiring, independence from CachyOS (no
#            [cachy*] repo, mirror, mirrorlist, package or kernel), laptop
#            profile, and every lane package actually installed
#   release  sign the ISO with the repo key, upload ISO + sums + signature +
#            manifests to the public iso container, write out/RELEASE
#
# Stages run in the order given (default: all, in that order). The first
# failure stops the run with "## STAGE <name> FAIL" in out/forge.log and a
# non-zero exit; every stage is idempotent, so a rerun after the fix picks
# up at the failed stage. Deallocating is the laptop's job: a VM cannot
# deallocate itself, and a guest shutdown still bills.
# R4 review fixes folded in (2026-09-05): B1, M2 (run identity), M3, m1-m5,
# m12, m13, m15, m16, m18, D-B (separate iso container + SAS), D-D audit.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"    # astroos/
repo="$(cd "$here/.." && pwd)"
out="$repo/out"
log="$out/forge.log"
status="$out/forge.status"
account="${ASTROOS_REPO_ACCOUNT:-astroosrepo}"
container="${ASTROOS_REPO_CONTAINER:-repo}"
iso_container="${ASTROOS_ISO_CONTAINER:-iso}"
keys="${ASTROOS_REPO_KEYS:-$HOME/astroos-repo-keys}"
iso_sas_file="${ASTROOS_ISO_SAS:-$HOME/astroos-iso.sas}"
IMG="${ASTROOS_BUILDER_IMAGE:-docker.io/archlinux:base-devel}"
blob="https://${account}.blob.core.windows.net/${container}"
iso_blob="https://${account}.blob.core.windows.net/${iso_container}"
repo_url="$blob/astroos/x86_64"
kr_dir="$here/pkgs/astroos-keyring/files/usr/share/pacman/keyrings"
export ASTROOS_WITH_AUR_REPO="${ASTROOS_WITH_AUR_REPO:-1}"

stages=("$@")
(( ${#stages[@]} )) || stages=(repo publish verify iso gate audit release)
# validate every argument before running anything (review m5)
for s in "${stages[@]}"; do
  case "$s" in repo|publish|verify|iso|gate|audit|release) ;; *) echo "!! unknown stage: $s" >&2; exit 2 ;; esac
done

mkdir -p "$out"
ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
say()  { echo "[$(ts)] $*" | tee -a "$log"; }
mark() { echo "$(ts) $1 $2" >> "$status"; }
die()  { say "!! $*"; exit 1; }
aur_names()   { tr -d '\r' < "$here/meta/aur.list" | grep -vE '^\s*(#|$)' | awk '{print $1}'; }
local_names() { local d; for d in "$here"/pkgs/*/; do [[ -f "$d/PKGBUILD" ]] && basename "$d"; done; return 0; }
# A pkgs/<name>/splits file names the extra pkgnames one PKGBUILD produces (the
# kernels: base, headers, zfs, nvidia-open from a single build). They are real
# db entries, so the hosted-db comparison must expect them; they are not build
# units, so the "every scope package is installed" audit does not demand them.
split_names() { local d; for d in "$here"/pkgs/*/; do [[ -f "$d/splits" ]] && tr -d '\r' < "$d/splits" | grep -vE '^\s*(#|$)' | awk '{print $1}'; done; return 0; }
scope_names() { { aur_names; local_names; } | sort -u; }
repo_names()  { { aur_names; local_names; split_names; } | sort -u; }
db_names()    { bsdtar -tf "$1" | awk -F/ '$2=="desc"{print $1}' | sed 's/-[^-]*-[^-]*$//' | sort -u; }
latest_iso()  { ls -1t "$out"/*.iso 2>/dev/null | head -1; }
fpr_expect()  { tr -d ' \r\n' < "$here/branding/REPO_FINGERPRINT"; }

# run identity (review M2): stale manifests from earlier runs must never be
# collected as this run's; forge-remote records only a RELEASE carrying this
# run's start stamp
run_start=$(date +%s)
echo "$run_start" > "$out/RUN_START"
rm -f "$out/RELEASE" "$out/audit.txt"
: > "$status"

cur=""
# shellcheck disable=SC2154  # rc is assigned inside the trap string
# the audit mount must not outlive a failing audit (review m4): a set -e exit
# skips the function's RETURN trap, so the umount lives here as well
trap 'rc=$?; sudo umount /mnt/astroos-audit 2>/dev/null || true; if [[ $rc -ne 0 && -n "$cur" ]]; then mark "$cur" FAIL; say "## STAGE $cur FAIL (rc=$rc)"; fi' EXIT

# --- repo / publish: the ratified lane script -------------------------------
# The summary filter keeps only >>/!! lines on the console; the inner `|| true`
# neutralises grep's no-match status without touching the pipeline's status
# (pipefail carries the lane script's exit into the if). Review B1.
stage_repo() {
  if ! bash "$here/scripts/build-aur-repo.sh" build 2>&1 | tee -a "$log" | { grep -E '^(>>|!!)' || true; }; then
    die "repo build failed (see $log)"
  fi
}
stage_publish() {
  if ! bash "$here/scripts/build-aur-repo.sh" publish 2>&1 | tee -a "$log" | { grep -E '^(>>|!!)' || true; }; then
    die "publish failed (see $log)"
  fi
}

# --- verify: the HOSTED repo, as a client sees it ---------------------------
stage_verify() {
  local v; v=$(mktemp -d)
  local fpr; fpr=$(fpr_expect)
  [[ "$(tr -d ' \r\n' < "$kr_dir/astroos-trusted")" == "${fpr}:4:" ]] \
    || die "astroos-trusted must read '${fpr}:4:' (is: $(cat "$kr_dir/astroos-trusted"))"
  say "verify: fetching hosted db, files, lock + signatures from $repo_url"
  local f
  for f in astroos.db astroos.db.sig astroos.files astroos.files.sig aur-map.lock aur-map.lock.sig aur-map.lock.sha256; do
    curl -sfL "$repo_url/$f" -o "$v/$f" || die "hosted $f unreachable"
  done
  # 1. signatures verify against the SHIPPED keyring (exactly what clients trust)
  gpg --batch --no-default-keyring --keyring "$v/kr.gpg" --import "$kr_dir/astroos.gpg" >/dev/null 2>&1
  for f in astroos.db astroos.files aur-map.lock; do
    gpg --batch --no-default-keyring --keyring "$v/kr.gpg" --verify "$v/$f.sig" "$v/$f" >/dev/null 2>"$v/gpg.err" \
      || die "hosted $f signature does NOT verify with the shipped keyring: $(tr '\n' ' ' < "$v/gpg.err")"
  done
  [[ "$(sha256sum "$v/aur-map.lock" | awk '{print $1}')" == "$(tr -d ' \r\n' < "$v/aur-map.lock.sha256")" ]] \
    || die "hosted aur-map.lock sha256 mismatch"
  say "verify: db, files and lock signatures OK against the shipped keyring $fpr"
  # 2. name set == aur.list ∪ pkgs/, the same D4 check container-build.sh performs
  local want have
  want=$(repo_names); have=$(db_names "$v/astroos.db")
  if [[ "$want" != "$have" ]]; then
    diff <(echo "$want") <(echo "$have") | tee -a "$log" || true
    die "hosted db name set != aur.list ∪ pkgs/ (D4)"
  fi
  say "verify: hosted db carries exactly the $(echo "$have" | wc -l) names ($(aur_names | wc -l) AUR + $(local_names | wc -l) local + $(split_names | wc -l) split)"
  # 3. a fresh client trusts the key through the SHIPPED trust path (keyring
  #    trio + pacman-key --populate, what pacman-init.service does on the live
  #    ISO; review M3), resolves every name and installs real packages under
  #    SigLevel Required
  local names; names=$(echo "$want" | tr '\n' ' ')
  podman run --rm --pids-limit=-1 -v "$kr_dir":/kr:ro -v astroos-pacman-cache:/var/cache/pacman/pkg "$IMG" bash -c '
    set -e
    install -m644 /kr/astroos.gpg /kr/astroos-trusted /kr/astroos-revoked /usr/share/pacman/keyrings/
    pacman-key --init >/dev/null 2>&1
    pacman-key --populate archlinux astroos >/dev/null 2>&1
    pacman-key --list-keys '"$fpr"' >/dev/null 2>&1 || { echo "!! key not in the populated keyring" >&2; exit 1; }
    # trust now lives in the populated keyring; hand the files over to the
    # astroos-keyring package below (a fresh root, as pacstrap and the
    # installer produce, never has them pre-placed)
    rm /usr/share/pacman/keyrings/astroos.gpg /usr/share/pacman/keyrings/astroos-trusted /usr/share/pacman/keyrings/astroos-revoked
    printf "\n[astroos]\nSigLevel = Required DatabaseOptional\nServer = '"$repo_url"'\n" >> /etc/pacman.conf
    pacman -Sy >/dev/null
    pacman -Sp --noconfirm '"$names"' >/dev/null
    pacman -S --noconfirm astroos-keyring astroos-branding astroos-tools astroos-calamares astroos-zenbook-duo siril-git ds9-bin opendrop python-healpy astromatic-swarp >/dev/null
    pacman -Q astroos-keyring astroos-branding astroos-tools astroos-calamares astroos-zenbook-duo siril-git ds9-bin opendrop python-healpy astromatic-swarp
    test -x /usr/bin/astroos-doctor
    test -f /etc/pacman.d/hooks/zz-astroos-identity.hook
    test -f /usr/share/calamares/branding/astroos/branding.desc
    # the Zenbook Duo runtime is built from source: every shared library it
    # links must resolve on a client, and its DMI gate must say no here
    for b in /usr/lib/zenbook-duo/zenbook-duo-*; do
      if ldd "$b" | grep -q "not found"; then echo "!! unresolved libraries in $b:" >&2; ldd "$b" | grep "not found" >&2; exit 1; fi
    done
    if /usr/lib/zenbook-duo/astroos-is-duo; then echo "!! astroos-is-duo claims this container is a Zenbook Duo" >&2; exit 1; fi' 2>&1 | tee -a "$log" \
    || die "client install test against the hosted repo FAILED"
  say "verify: fresh client resolved all $(echo "$have" | wc -l) names and installed 10 packages with signature verification"
  rm -rf "$v"
}

# --- iso / gate -------------------------------------------------------------
stage_iso() {
  say "iso: release build (ASTROOS_WITH_AUR_REPO=$ASTROOS_WITH_AUR_REPO ASTROOS_WITH_BLACKARCH=${ASTROOS_WITH_BLACKARCH:-0} ASTROOS_FAST=${ASTROOS_FAST:-0})"
  local commit; commit=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)
  # shellcheck disable=SC2024  # the log is meant to be written as the invoking user, not root
  sudo env ASTROOS_WITH_AUR_REPO="$ASTROOS_WITH_AUR_REPO" ASTROOS_WITH_BLACKARCH="${ASTROOS_WITH_BLACKARCH:-0}" \
           ASTROOS_FAST="${ASTROOS_FAST:-0}" ASTROOS_SIZE_BUDGET_MIB="${ASTROOS_SIZE_BUDGET_MIB:-7600}" \
           ASTROOS_ALLOW_UNBRANDED="${ASTROOS_ALLOW_UNBRANDED:-0}" ASTROOS_COMMIT="$commit" \
       bash "$here/scripts/build-iso.sh" >> "$log" 2>&1 || die "iso build failed (tail: $(tail -3 "$log" | tr '\n' ' '))"
  say "iso: $(basename "$(latest_iso)") $(grep -E '^iso_bytes=' "$out/build-metadata.txt" | cut -d= -f2) bytes"
}
stage_gate() {
  bash "$here/scripts/qemu-smoke.sh" >> "$log" 2>&1 || die "boot gate FAILED (out/qemu-smoke.log)"
  say "gate: PASS 5/5"
}

# --- audit: inside the artifact ---------------------------------------------
stage_audit() {
  local iso; iso=$(latest_iso); [[ -n "$iso" ]] || die "no ISO in out/"
  command -v unsquashfs >/dev/null || sudo apt-get install -y -qq squashfs-tools >/dev/null
  local m=/mnt/astroos-audit a; a=$(mktemp -d)
  sudo mkdir -p "$m"; sudo umount "$m" 2>/dev/null || true
  sudo mount -o loop,ro "$iso" "$m" || die "cannot loop-mount $iso"
  # the mount must not outlive a failing audit (review m4)
  trap 'sudo umount /mnt/astroos-audit 2>/dev/null || true' RETURN
  local sfs="$m/arch/x86_64/airootfs.sfs"; [[ -f "$sfs" ]] || die "airootfs.sfs missing in ISO"
  local fail=0 pass=0 rep="$out/audit.txt"
  : > "$rep"
  ok()  { echo "  [ok] $1" | tee -a "$rep"; pass=$((pass+1)); }
  bad() { echo "  [FAIL] $1" | tee -a "$rep"; fail=$((fail+1)); }
  echo "AstroOS content audit: $(basename "$iso") $(ts)" | tee -a "$rep"
  # files of interest, extracted without unpacking the whole image (no -q:
  # not every squashfs-tools accepts it, review m2; the extraction must work)
  unsquashfs -n -d "$a/root" "$sfs" \
    etc/os-release usr/lib/os-release etc/lsb-release etc/issue etc/motd etc/hostname etc/astroos-release \
    etc/pacman.conf etc/pacman-more.conf etc/pacman.d/hooks etc/pacman.d/blackarch-mirrorlist \
    etc/pacman.d/cachyos-mirrorlist etc/pacman.d/cachyos-v3-mirrorlist etc/pacman.d/cachyos-v4-mirrorlist \
    etc/pacman.d/astroos-mirrorlist \
    etc/fastfetch usr/share/astroos usr/share/pacman/keyrings \
    usr/share/plymouth/themes/astroos etc/plymouth/plymouthd.conf usr/bin/astroos-doctor \
    usr/share/calamares/settings_online.conf usr/share/calamares/branding/astroos \
    etc/calamares/modules etc/calamares/scripts \
    etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc etc/skel/.config/alacritty/alacritty.toml \
    etc/skel/.config/plasma-welcomerc etc/skel/.config/zenbook-duo \
    usr/share/applications/astroos-install.desktop usr/share/applications/cachyos-hello.desktop \
    usr/lib/zenbook-duo usr/lib/systemd/system/zenbook-duo-rust-daemon.service \
    etc/cachyos-release usr/share/icons/cachyos.svg \
    usr/share/icons/hicolor/scalable/apps/astroos-logo.svg \
    usr/share/refind/icons/os_astroos.png \
    usr/share/sddm/themes/breeze/theme.conf.user \
    usr/lib/plasmalogin/plasmalogin.conf.d usr/share/doc/astroos \
    usr/share/color-schemes/AstroOS.colors usr/share/plasma/look-and-feel/org.astroos.desktop \
    usr/share/konsole/AstroOS.colorscheme usr/share/konsole/AstroOS.profile \
    usr/share/grub/themes/astroos var/lib/sddm/.config \
    etc/skel/.config/kdeglobals etc/skel/.config/kdedefaults \
    etc/skel/.config/konsolerc etc/skel/.config/kscreenlockerrc \
    usr/share/libalpm/hooks usr/lib/calamares/modules/pacstrap \
    usr/share/glib-2.0/schemas/zz_astroos.org.gnome.login-screen.gschema.override \
    >/dev/null 2>"$a/unsquash.err" || true
  local r="$a/root"
  [[ -s "$r/etc/os-release" ]] || die "unsquashfs extraction failed: $(tr '\n' ' ' < "$a/unsquash.err")"

  # identity (live session)
  grep -q '^NAME="AstroOS"' "$r/etc/os-release" 2>/dev/null && ok "etc/os-release NAME=AstroOS" || bad "etc/os-release is not AstroOS"
  grep -q '^NAME="AstroOS"' "$r/usr/lib/os-release" 2>/dev/null && ok "usr/lib/os-release NAME=AstroOS" || bad "usr/lib/os-release is not AstroOS"
  grep -qi cachyos "$r/etc/os-release" "$r/etc/lsb-release" 2>/dev/null && bad "CachyOS string survives in identity files" || ok "no CachyOS string in identity files"
  grep -q '^DISTRIB_ID=AstroOS' "$r/etc/lsb-release" 2>/dev/null && ok "lsb-release DISTRIB_ID=AstroOS" || bad "lsb-release not AstroOS"
  grep -q AstroOS "$r/etc/issue" 2>/dev/null && ok "/etc/issue branded" || bad "/etc/issue not branded"
  [[ "$(tr -d '\r\n' < "$r/etc/hostname" 2>/dev/null)" == "astroos" ]] && ok "hostname is astroos" || bad "hostname is not astroos"
  if grep -q 'Welcome to AstroOS' "$r/etc/motd" 2>/dev/null && ! grep -qi 'welcome to your.*cachyos' "$r/etc/motd"; then ok "motd is the AstroOS one"; else bad "motd missing or still CachyOS"; fi
  # the watermark now lives in our own Plymouth theme (astroos-theme), not in
  # plymouth's stock spinner theme: same asset, new owner
  [[ "$(sha256sum "$r/usr/share/plymouth/themes/astroos/watermark.png" 2>/dev/null | cut -d' ' -f1)" == "$(sha256sum "$here/branding/out/watermark.png" | cut -d' ' -f1)" ]] \
    && ok "plymouth watermark is the AstroOS asset" || bad "plymouth watermark is not ours"
  [[ -s "$r/etc/fastfetch/astroos-logo.ansi" ]] && ok "fastfetch ANSI logo shipped" || bad "fastfetch logo missing"
  [[ -x "$r/usr/bin/astroos-doctor" ]] && ok "astroos-doctor executable (packaged, /usr/bin)" || bad "astroos-doctor missing or not executable"
  [[ -f "$r/etc/pacman.d/hooks/zz-astroos-identity.hook" ]] && ok "identity hook shipped" || bad "identity hook missing"
  # The /dev/null masks that once silenced cachyos-hooks went with that
  # package. What must hold now: branding's identity hooks live under
  # /etc/pacman.d/hooks, astroos-hooks' machinery under /usr/share/libalpm/hooks,
  # and no hook anywhere carries a CachyOS name, masked or real.
  local h cachy_hooks
  for h in astroos-reboot-required.hook astroos-plymouth-initramfs.hook; do
    [[ -f "$r/usr/share/libalpm/hooks/$h" ]] && ok "$h shipped by astroos-hooks" || bad "$h missing from usr/share/libalpm/hooks"
  done
  cachy_hooks=$(find "$r/etc/pacman.d/hooks" "$r/usr/share/libalpm/hooks" -maxdepth 1 -iname '*cachy*' -printf '%f ' 2>/dev/null)
  [[ -n "$cachy_hooks" ]] && bad "a CachyOS-named hook survives: $cachy_hooks" || ok "no CachyOS-named hook in either hook directory"
  [[ -f "$r/usr/share/applications/cachyos-hello.desktop" ]] && bad "cachyos-hello still on the ISO" || ok "cachyos-hello gone"
  [[ -f "$r/usr/share/applications/astroos-install.desktop" ]] && ok "Install AstroOS launcher shipped" || bad "astroos-install.desktop missing"
  # Installer configuration AFTER apply.sh has run at pacstrap time. The old
  # rewrite touched capitalised titles only, so the hidden "required"
  # netinstall group and pacstrap's base list kept lowercase cachyos package
  # names, and a target with no [cachyos] repository aborted on them. The
  # positive control comes first: an absent file would pass every absence
  # check below vacuously.
  [[ -s "$r/etc/calamares/modules/netinstall.yaml" ]] && ok "netinstall.yaml extracted (positive control)" || bad "netinstall.yaml missing from the image"
  grep -qi cachy "$r/etc/calamares/modules/netinstall.yaml" 2>/dev/null && bad "netinstall.yaml still names a CachyOS package: $(grep -i cachy "$r/etc/calamares/modules/netinstall.yaml" | head -3 | tr -s ' \n' ' ')" || ok "netinstall.yaml carries no cachy name"
  grep -qi cachy "$r/etc/calamares/modules/pacstrap.conf" 2>/dev/null && bad "pacstrap.conf still names a CachyOS package" || ok "pacstrap.conf carries no cachy name"
  grep -q cachyos "$r/etc/calamares/modules/shellprocess_initialize_pacman.conf" 2>/dev/null && bad "shellprocess still copies a cachyos mirrorlist (install aborts on the missing file)" || ok "shellprocess copies the AstroOS mirrorlists"
  grep -q 'linux-astroos' "$r/usr/lib/calamares/modules/pacstrap/main.py" 2>/dev/null && ok "pacstrap module installs linux-astroos" || bad "pacstrap module does not name linux-astroos"
  grep -q 'astroos-rate-mirrors' "$r/etc/calamares/scripts/update-mirrorlist" 2>/dev/null && ok "update-mirrorlist calls astroos-rate-mirrors" || bad "update-mirrorlist still calls the CachyOS tool (exit 127 aborts the install)"
  # plasma-welcome looks the value up with KService::serviceByDesktopName: the desktop file NAME without the suffix.
  # "astroos-install.desktop" rendered an empty icon whose click did nothing
  # (2026-09-05 E2E), so the check pins the exact value and the file it names.
  li=$(sed -n 's/^LiveInstaller=//p' "$r/etc/skel/.config/plasma-welcomerc" 2>/dev/null | tr -d '\r')
  if [[ "$li" == "astroos-install" && -f "$r/usr/share/applications/${li}.desktop" ]]; then ok "plasma-welcome Install button wired (LiveInstaller=$li, desktop file present)"; else bad "plasma-welcomerc LiveInstaller is '${li:-unset}' (must be astroos-install, no .desktop suffix, file present)"; fi
  # skeleton configs: astroos-kde-settings ships the Plasma appletsrc already
  # branded, so nothing at pacstrap time has to sed it any more
  local ap="$r/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc"
  if [[ -f "$ap" ]]; then
    grep -q '^icon=astroos-logo' "$ap" && ok "Kickoff icon is astroos-logo" || bad "Kickoff icon not rebranded"
    grep -q 'cachyos-wallpapers' "$ap" && bad "cachyos-wallpapers path survives in appletsrc" || ok "default wallpaper points at AstroOS"
  else bad "appletsrc missing (astroos-kde-settings not installed?)"; fi
  # cachyos-alacritty-config left with [cachyos] and no AstroOS package ships an
  # Alacritty config, so the file is normally absent; should one return, it
  # must not carry the CachyOS title
  local al="$r/etc/skel/.config/alacritty/alacritty.toml"
  if [[ -f "$al" ]]; then grep -qi cachyos "$al" && bad "alacritty.toml still names CachyOS" || ok "alacritty.toml carries no CachyOS"
  else ok "no CachyOS Alacritty config shipped"; fi

  # repo wiring (live + installed-system pacman.conf)
  if [[ "$ASTROOS_WITH_AUR_REPO" == "1" ]]; then
    local c
    for c in etc/pacman.conf etc/pacman-more.conf; do
      if grep -q '^\[astroos\]' "$r/$c" 2>/dev/null && grep -A3 '^\[astroos\]' "$r/$c" | grep -qF "Server = $blob/astroos/\$arch" \
         && grep -A3 '^\[astroos\]' "$r/$c" | grep -q '^SigLevel = Required'; then
        ok "[astroos] section complete in $c"
      else bad "[astroos] section missing/incomplete in $c"; fi
    done
    local shipfpr; shipfpr=$(gpg --show-keys --with-colons "$r/usr/share/pacman/keyrings/astroos.gpg" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
    [[ "$shipfpr" == "$(fpr_expect)" ]] && ok "shipped astroos keyring fingerprint matches" || bad "shipped keyring fingerprint mismatch ($shipfpr)"
    [[ "$(tr -d ' \r\n' < "$r/usr/share/pacman/keyrings/astroos-trusted" 2>/dev/null)" == "$(fpr_expect):4:" ]] \
      && ok "astroos-trusted grants ownertrust 4 to the repo key" || bad "astroos-trusted wrong or missing"
  fi
  # independence: no pacman configuration in the image may enable a CachyOS
  # repository or name their mirror, and etc/pacman.d carries our mirrorlist
  # instead of theirs. Every path below is in the unsquashfs list above, and
  # each file is asserted PRESENT before the absence checks that read beside
  # it, so an absence check can never pass because the path was never
  # extracted (R4.3). These run unconditionally: dropping [cachyos] is not
  # gated on ASTROOS_WITH_AUR_REPO.
  local pc
  for pc in etc/pacman.conf etc/pacman-more.conf; do
    if [[ -s "$r/$pc" ]]; then
      ok "$pc extracted (positive control for the two checks below)"
      grep -qE '^\[cachy' "$r/$pc" && bad "$pc still enables a CachyOS repository" || ok "no [cachy*] section in $pc"
      grep -qF 'mirror.cachyos.org' "$r/$pc" && bad "$pc still names mirror.cachyos.org" || ok "no CachyOS mirror server line in $pc"
    else
      bad "$pc missing or empty in the image (CachyOS repo independence untested)"
    fi
  done
  if [[ -s "$r/etc/pacman.d/astroos-mirrorlist" ]]; then
    ok "etc/pacman.d/astroos-mirrorlist shipped (positive control: etc/pacman.d was extracted)"
    local ml survivors=""
    for ml in cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist; do
      [[ ! -e "$r/etc/pacman.d/$ml" ]] || survivors="$survivors $ml"
    done
    [[ -z "$survivors" ]] && ok "no CachyOS mirrorlist in etc/pacman.d" || bad "CachyOS mirrorlists survive in etc/pacman.d:$survivors"
  else
    bad "etc/pacman.d/astroos-mirrorlist missing (astroos-mirrorlist not installed?)"
  fi
  if [[ "${ASTROOS_WITH_BLACKARCH:-0}" == "1" ]]; then
    for c in etc/pacman.conf etc/pacman-more.conf; do
      grep -q '^\[blackarch\]' "$r/$c" 2>/dev/null && ok "[blackarch] repo in $c" || bad "[blackarch] missing from $c"
    done
    [[ -s "$r/usr/share/pacman/keyrings/blackarch.gpg" ]] && ok "blackarch keyring shipped" || bad "blackarch keyring missing"
    grep -qE '^Server = ' "$r/etc/pacman.d/blackarch-mirrorlist" 2>/dev/null && ok "blackarch mirrorlist has an active Server line" || bad "blackarch mirrorlist has no active Server line"
  fi

  # installer configuration (applied by astroos-calamares' hook at pacstrap time)
  grep -q '^branding: astroos' "$r/usr/share/calamares/settings_online.conf" 2>/dev/null && ok "installer selects the astroos branding" || bad "installer branding not astroos"
  grep -q '^\s*productName:\s*AstroOS' "$r/usr/share/calamares/branding/astroos/branding.desc" 2>/dev/null && ok "installer branding.desc says AstroOS" || bad "branding.desc missing/wrong"
  local cm="$r/etc/calamares/modules"
  grep -v '^\s*#' "$cm/netinstall.conf" 2>/dev/null | grep -q 'githubusercontent' && bad "netinstall.conf still pulls groups from GitHub" || ok "netinstall groups are local-only"
  grep -q '^\s*- cachyos-hello\s*$' "$cm/netinstall.yaml" 2>/dev/null && bad "cachyos-hello survives in netinstall.yaml" || ok "cachyos-hello not in the installed set"
  grep -q '^- name: "AstroOS (hidden)"' "$cm/netinstall.yaml" 2>/dev/null && ok "AstroOS package groups present in netinstall.yaml" || bad "AstroOS groups missing from netinstall.yaml"
  if [[ "${ASTROOS_WITH_BLACKARCH:-0}" == "1" ]]; then
    grep -q '^- name: "BlackArch tools"' "$cm/netinstall.yaml" 2>/dev/null && ok "BlackArch group present in netinstall.yaml" || bad "BlackArch group missing from netinstall.yaml"
  fi
  grep -q '^\s*- astroos-branding\s*$' "$cm/pacstrap.conf" 2>/dev/null && ok "astroos-branding in pacstrap basePackages" || bad "astroos-branding not pacstrapped"
  grep -q 'cachyos-plymouth' "$cm/pacstrap.conf" 2>/dev/null && bad "CachyOS plymouth themes still pacstrapped" || ok "CachyOS plymouth themes out of pacstrap"
  grep -q '^\s*template:\s*"astroos"' "$cm/users.conf" 2>/dev/null && ok "installed hostname template is astroos" || bad "hostname template not astroos"
  grep -q '^efiBootloaderId: "astroos"' "$cm/bootloader.conf" 2>/dev/null && ok "EFI boot entry id is astroos" || bad "EFI boot entry id not astroos"
  # the installer writes GRUB_THEME into the target's /etc/default/grub, so it
  # has to name the AstroOS theme (astroos-grub-theme): not the CachyOS one it
  # replaced, and not nothing, or an installed GRUB menu is GRUB's own blue
  grep -q '^\s*GRUB_THEME: "/usr/share/grub/themes/astroos/theme.txt"$' "$cm/grubcfg.conf" 2>/dev/null \
    && ok "installer selects the AstroOS GRUB theme" || bad "grubcfg.conf does not select /usr/share/grub/themes/astroos/theme.txt"
  grep -q 'themes/cachyos' "$cm/grubcfg.conf" 2>/dev/null && bad "CachyOS GRUB theme still configured" || ok "no CachyOS GRUB theme"
  # the plymouthcfg module writes the installed system's theme after pacstrap,
  # so it has the last word over astroos-theme's .install: it must name our own
  # theme on both GPU paths, or the installed splash drops back to plymouth's
  # stock spinner and the boot leaves the colour scheme
  if grep -q '^plymouth_theme: astroos$' "$cm/plymouthcfg.conf" 2>/dev/null \
     && grep -q '^plymouth_theme_amdgpu: astroos$' "$cm/plymouthcfg.conf" 2>/dev/null; then
    ok "installer sets the installed plymouth theme to astroos (both GPU paths)"
  else bad "plymouthcfg.conf does not select the astroos plymouth theme on both GPU paths"; fi
  grep -q 'CachyOS' "$r/etc/calamares/scripts/bootloader-post-setup" "$r/etc/calamares/scripts/btrfs-installation-snapshot" 2>/dev/null \
    && bad "CachyOS survives in the installer scripts (Limine name / snapshot description)" || ok "installer scripts say AstroOS"
  # installer previews and the last CachyOS surfaces (2026-09-06)
  grep -q 'screenshot: "/usr/share/astroos/calamares/images/bootloaders/limine.png"' "$cm/packagechooser_bootloader.conf" 2>/dev/null \
    && ok "bootloader page previews are AstroOS images" || bad "bootloader page still shows upstream previews"
  grep -q 'screenshot: "/usr/share/astroos/calamares/images/desktops/plasma.png"' "$cm/packagechooser_desktop.conf" 2>/dev/null \
    && ok "desktop page previews are AstroOS images" || bad "desktop page still shows upstream previews"
  local pv missing_pv=0
  for pv in bootloaders/grub bootloaders/limine bootloaders/refind bootloaders/systemd-boot desktops/plasma desktops/gnome; do
    [[ -f "$r/usr/share/astroos/calamares/images/$pv.png" ]] || missing_pv=1
  done
  (( missing_pv == 0 )) && ok "AstroOS preview images present" || bad "AstroOS preview images missing"
  grep -l 'CachyOS' "$cm/netinstall.yaml" "$cm/packagechooser_desktop.conf" "$cm/packagechooser_bootloader.conf" "$cm/welcome_online.conf" 2>/dev/null | grep -q . \
    && bad "CachyOS survives in the installer module configs" || ok "no CachyOS string in the installer module configs"
  grep -q '^\s*GRUB_BACKGROUND: "/usr/share/astroos/branding/limine-splash.png"' "$cm/grubcfg.conf" 2>/dev/null \
    && ok "GRUB gets the AstroOS background" || bad "GRUB_BACKGROUND not configured"
  # every path below has to be in the unsquashfs list above, or an absence check
  # passes for the wrong reason: astroos-logo.svg is the positive control that
  # proves usr/share/icons was extracted at all
  [[ -f "$r/usr/share/icons/hicolor/scalable/apps/astroos-logo.svg" ]] && ok "scalable astroos-logo.svg shipped" || bad "astroos-logo.svg missing"
  # Qt's SVG engine (Plasma's icon loader) implements neither, and draws the
  # shape unclipped rather than failing: R4.4, arcs across the planet's face
  grep -qE 'clip-path|clipPath|<filter|feGaussian' "$r/usr/share/icons/hicolor/scalable/apps/astroos-logo.svg" 2>/dev/null     && bad "the scalable logo uses SVG features Qt ignores" || ok "scalable logo stays inside what Qt renders"
  [[ -e "$r/etc/cachyos-release" ]] && bad "/etc/cachyos-release survives on the live ISO" || ok "no /etc/cachyos-release"
  [[ -e "$r/usr/share/icons/cachyos.svg" ]] && bad "CachyOS icon file survives" || ok "no CachyOS icon file"
  [[ -f "$r/usr/share/refind/icons/os_astroos.png" ]] && ok "rEFInd OS icon shipped" || bad "rEFInd OS icon missing"
  grep -q '^background=/usr/share/astroos/branding/login-background.png' "$r/usr/share/sddm/themes/breeze/theme.conf.user" 2>/dev/null \
    && ok "SDDM greeter background is the AstroOS wallpaper" || bad "SDDM greeter background not branded"
  grep -rq 'login-background.png' "$r/usr/lib/plasmalogin/plasmalogin.conf.d" 2>/dev/null \
    && ok "plasmalogin greeter wallpaper drop-in shipped" || bad "plasmalogin wallpaper drop-in missing"
  grep -q 'astroos-logo' "$r/usr/share/glib-2.0/schemas/zz_astroos.org.gnome.login-screen.gschema.override" 2>/dev/null \
    && ok "GNOME login logo override shipped" || bad "GNOME login logo override missing"
  [[ -f "$r/usr/share/astroos/branding/login-background.png" ]] && ok "greeter background shipped" || bad "greeter background missing"
  grep -q '^AstroOS rolling' "$r/etc/astroos-release" 2>/dev/null && ok "/etc/astroos-release shipped" || bad "/etc/astroos-release missing"
  # house style: no em dash in anything we print (owner directive, 2026-09-06)
  LC_ALL=C grep -rl $'\xe2\x80\x94' "$r/etc/astroos-release" "$r/etc/motd" "$r/etc/issue" "$r/usr/share/astroos/branding" 2>/dev/null | grep -q . \
    && bad "em dash in the shipped identity text" || ok "no em dash in the shipped identity text"
  # our own prose, read on the installed system; code under usr/share/astroos is
  # exempt because apply.sh carries the string as a sed pattern
  if [[ -d "$r/usr/share/doc/astroos" ]]; then
    grep -rqi cachyos "$r/usr/share/doc/astroos" && bad "CachyOS survives in the shipped AstroOS docs" || ok "no CachyOS string in the shipped AstroOS docs"
  else
    bad "shipped AstroOS docs missing"
  fi

  # one colour scheme, every surface: astroos-theme (KDE scheme, look-and-feel,
  # Konsole, Plymouth), astroos-grub-theme, and the skeleton that selects them.
  # Same discipline as the independence block above: every path here is in the
  # unsquashfs list, and each absence check sits behind a positive control, so
  # a "no BreezeDark" verdict can never pass because the tree was never
  # extracted (R4.3). The recursive BreezeDark search sees the skeleton files
  # in that list (kdeglobals, kdedefaults, konsolerc, kscreenlockerrc,
  # appletsrc, plasma-welcomerc), which is where a stale scheme name would sit.
  local cs="$r/usr/share/color-schemes/AstroOS.colors"
  if [[ -s "$cs" ]]; then
    ok "AstroOS.colors extracted (positive control for the colour scheme checks)"
    sed -n '/^\[General\]/,/^\[/p' "$cs" | grep -q '^Name=AstroOS$' \
      && ok "AstroOS.colors is named AstroOS ([General] Name)" || bad "AstroOS.colors carries no [General] Name=AstroOS (nothing would select it by name)"
  else
    bad "usr/share/color-schemes/AstroOS.colors missing from the image (astroos-theme not installed?)"
  fi
  local sk="$r/etc/skel/.config"
  if [[ -s "$sk/kdeglobals" ]]; then
    ok "skel kdeglobals extracted (positive control for the skeleton colour checks)"
    grep -q '^ColorScheme=AstroOS$' "$sk/kdeglobals" && ok "skel kdeglobals selects ColorScheme=AstroOS" || bad "skel kdeglobals does not select ColorScheme=AstroOS"
    grep -q '^LookAndFeelPackage=org.astroos.desktop$' "$sk/kdeglobals" && ok "skel kdeglobals selects LookAndFeelPackage=org.astroos.desktop" || bad "skel kdeglobals does not select the AstroOS look-and-feel"
    local breeze
    breeze=$({ grep -rl '^ColorScheme=BreezeDark' "$sk" || true; } | sed "s|^$sk/||" | tr '\n' ' ')
    [[ -z "$breeze" ]] && ok "no ColorScheme=BreezeDark under etc/skel/.config" || bad "BreezeDark still selected in the skeleton: $breeze"
  else
    bad "etc/skel/.config/kdeglobals missing from the image (the skeleton colour checks could not run)"
  fi
  local kd="$sk/kdedefaults"
  grep -q '^ColorScheme=AstroOS$' "$kd/kdeglobals" 2>/dev/null \
    && ok "skel kdedefaults/kdeglobals selects AstroOS (the defaults layer Plasma reads first)" || bad "kdedefaults/kdeglobals does not select AstroOS"
  sed -n '/^\[Theme\]/,/^\[/p' "$kd/plasmarc" 2>/dev/null | grep -q '^name=default$' \
    && ok "skel kdedefaults/plasmarc keeps [Theme] name=default (Breeze follows the colour scheme)" || bad "kdedefaults/plasmarc does not keep [Theme] name=default"
  local lnf="$r/usr/share/plasma/look-and-feel/org.astroos.desktop"
  [[ -s "$lnf/metadata.json" ]] && ok "look-and-feel org.astroos.desktop shipped (metadata.json)" || bad "look-and-feel org.astroos.desktop metadata.json missing"
  grep -q '^ColorScheme=AstroOS$' "$lnf/contents/defaults" 2>/dev/null \
    && ok "look-and-feel defaults name ColorScheme=AstroOS" || bad "look-and-feel contents/defaults does not name ColorScheme=AstroOS"
  [[ -s "$lnf/contents/splash/Splash.qml" ]] && ok "look-and-feel login splash shipped (Splash.qml)" || bad "look-and-feel contents/splash/Splash.qml missing"
  [[ -s "$r/usr/share/konsole/AstroOS.colorscheme" ]] && ok "Konsole colour scheme shipped" || bad "usr/share/konsole/AstroOS.colorscheme missing"
  [[ -s "$r/usr/share/konsole/AstroOS.profile" ]] && ok "Konsole AstroOS profile shipped" || bad "usr/share/konsole/AstroOS.profile missing"
  grep -q '^DefaultProfile=AstroOS.profile$' "$sk/konsolerc" 2>/dev/null \
    && ok "skel konsolerc opens the AstroOS profile" || bad "skel konsolerc does not set DefaultProfile=AstroOS.profile"
  local pt="$r/usr/share/plymouth/themes/astroos"
  [[ -s "$pt/astroos.plymouth" ]] && ok "Plymouth theme astroos.plymouth shipped" || bad "astroos.plymouth missing from the image"
  [[ -s "$pt/watermark.png" ]] && ok "Plymouth theme carries the watermark" || bad "watermark.png missing from the astroos Plymouth theme"
  local throb
  throb=$(find "$pt" -maxdepth 1 -name 'throbber-*.png' -printf '%f ' 2>/dev/null || true)
  [[ -n "$throb" ]] && ok "Plymouth throbber frames shipped ($(printf '%s' "$throb" | wc -w))" || bad "no throbber-*.png in the astroos Plymouth theme (the splash would not animate)"
  grep -q '^Theme=astroos$' "$r/etc/plymouth/plymouthd.conf" 2>/dev/null \
    && ok "plymouthd.conf selects Theme=astroos" || bad "etc/plymouth/plymouthd.conf does not select the astroos theme"
  grep -q '^ColorScheme=AstroOS$' "$r/var/lib/sddm/.config/kdeglobals" 2>/dev/null \
    && ok "SDDM greeter kdeglobals selects AstroOS" || bad "var/lib/sddm/.config/kdeglobals does not select AstroOS"
  [[ -s "$r/usr/share/grub/themes/astroos/theme.txt" ]] && ok "GRUB theme shipped (astroos-grub-theme)" || bad "usr/share/grub/themes/astroos/theme.txt missing"
  # astroos-theme owns Plymouth now: a leftover 85-astroos-plymouth-watermark
  # hook would keep copying the watermark into plymouth's stock spinner theme
  if [[ -d "$r/etc/pacman.d/hooks" ]]; then
    ok "etc/pacman.d/hooks extracted (positive control for the check below)"
    local wmhook
    wmhook=$(find "$r/etc/pacman.d/hooks" -maxdepth 1 -name '85-astroos-plymouth-watermark.hook' -printf '%f ' 2>/dev/null)
    [[ -z "$wmhook" ]] && ok "the retired watermark hook is gone" || bad "the retired watermark hook survives and fights the theme: $wmhook"
  else
    bad "etc/pacman.d/hooks missing from the image (the retired watermark hook could not be checked)"
  fi
  # every themed file that reached the image uses palette colours only: the
  # checker CI runs over the sources, pointed here at what the ISO carries.
  # A missing python3 is a finding, not a skip: unchecked is unproven.
  local pcheck="$here/branding/palette-check.py"
  local pf pmiss="" pfiles=()
  for pf in usr/share/color-schemes/AstroOS.colors \
            usr/share/konsole/AstroOS.colorscheme \
            usr/share/plasma/look-and-feel/org.astroos.desktop/contents/defaults \
            usr/share/plasma/look-and-feel/org.astroos.desktop/contents/splash/Splash.qml \
            usr/share/plymouth/themes/astroos/astroos.plymouth \
            usr/share/grub/themes/astroos/theme.txt \
            usr/share/calamares/branding/astroos/branding.desc \
            usr/share/calamares/branding/astroos/stylesheet.qss; do
    if [[ -f "$r/$pf" ]]; then pfiles+=("$r/$pf"); else pmiss="$pmiss $pf"; fi
  done
  if ! command -v python3 >/dev/null 2>&1; then
    bad "python3 missing on the build host: the ISO palette check could not run"
  elif [[ -n "$pmiss" ]]; then
    bad "themed files missing from the image, palette unchecked:$pmiss"
  elif python3 "$pcheck" "${pfiles[@]}" > "$a/palette.txt" 2>&1; then
    ok "every themed file on the ISO uses palette colours only ($(tail -1 "$a/palette.txt"))"
  else
    bad "a themed file on the ISO uses a colour outside the palette: $({ grep -m1 'is not in palette' "$a/palette.txt" || head -1 "$a/palette.txt"; } | sed "s|^$r/||")"
  fi

  # laptop profile
  [[ -x "$r/usr/lib/zenbook-duo/zenbook-duo-daemon" ]] && ok "Zenbook Duo runtime shipped" || bad "Zenbook Duo runtime missing"
  [[ -f "$r/etc/skel/.config/zenbook-duo/settings.json" ]] && ok "Zenbook Duo settings skeleton shipped" || bad "Zenbook Duo settings skeleton missing"

  # installed package set from the pacman local db inside the squashfs
  unsquashfs -l "$sfs" 2>/dev/null | grep -oE 'var/lib/pacman/local/[^/]+$' | sed 's|.*/||; s/-[^-]*-[^-]*$//' | sort -u > "$a/installed"
  local n_inst; n_inst=$(wc -l < "$a/installed")
  echo "  installed packages: $n_inst" | tee -a "$rep"
  local missing=()
  if [[ "$ASTROOS_WITH_AUR_REPO" == "1" ]]; then
    while read -r p; do grep -qx "$p" "$a/installed" || missing+=("$p"); done < <(scope_names)
    (( ${#missing[@]} == 0 )) && ok "every [astroos] scope package is installed in the image ($(scope_names | wc -l))" || bad "[astroos] packages NOT installed: ${missing[*]}"
  fi
  missing=()
  while read -r p; do grep -qx "$p" "$a/installed" || missing+=("$p"); done < <(grep -vE '^\s*(#|$)' "$here/astroos-additions.x86_64" | tr -d '\r')
  (( ${#missing[@]} == 0 )) && ok "every AstroOS addition is installed" || bad "additions NOT installed: ${missing[*]}"
  for p in cachyos-hello cachyos-cli-installer-new; do
    grep -qx "$p" "$a/installed" && bad "$p is installed" || ok "$p not installed"
  done
  # independence: no CachyOS package at all, which is the point of rebuilding
  # the [cachyos] scope under AstroOS names. n_inst is the positive control:
  # an empty listing is reported, never silently passed as an absence.
  if (( n_inst > 0 )); then
    local icachy; icachy=$({ grep -E '^cachy|^linux-cachyos' "$a/installed" || true; } | tr '\n' ' ')
    [[ -z "$icachy" ]] && ok "no CachyOS package installed in the image" || bad "CachyOS packages installed in the image: $icachy"
  else
    bad "the pacman local db listing is empty (CachyOS package check could not run)"
  fi
  # the shipped package manifest. container-build.sh copies the resolved
  # profile list to /build/out/manifest.pkglist and build-iso.sh bind-mounts
  # the repo checkout at /build, so it lands in out/ beside the ISO and
  # stage_release uploads it next to the ISO: it is a sibling artifact, NOT a
  # file inside the image. Auditing out/manifest.pkglist is therefore auditing
  # exactly the file a user downloads. It belongs to the run that built the
  # ISO, so a missing one is a finding rather than a skip.
  if [[ -s "$out/manifest.pkglist" ]]; then
    { grep -vE '^\s*(#|$)' "$out/manifest.pkglist" || true; } | tr -d '\r' | awk '{print $1}' | sort -u > "$a/manifest"
    ok "manifest.pkglist present beside the ISO ($(wc -l < "$a/manifest") entries)"
    local mcachy; mcachy=$({ grep -E '^cachy|^linux-cachyos' "$a/manifest" || true; } | tr '\n' ' ')
    [[ -z "$mcachy" ]] && ok "manifest.pkglist names no CachyOS package" || bad "manifest.pkglist names CachyOS packages: $mcachy"
  else
    bad "out/manifest.pkglist missing or empty (the shipped manifest could not be audited)"
  fi
  # the kernel is ours. usr/lib/modules is far too large to put in the
  # extraction list, so the evidence is the squashfs directory listing: a
  # second metadata pass, kept separate from the installed-package listing
  # above so that check keeps working exactly as it does today. The module
  # tree name is what uname -r reports, so it is the kernel's own identity.
  unsquashfs -l "$sfs" 2>/dev/null | grep -oE 'usr/lib/modules/[^/]+$' | sed 's|.*/||' | sort -u > "$a/kmods" || true
  local n_kmod; n_kmod=$(wc -l < "$a/kmods")
  if (( n_kmod > 0 )); then
    ok "kernel module trees in the image: $(tr '\n' ' ' < "$a/kmods")"
    grep -q -- '-astroos' "$a/kmods" && ok "an AstroOS kernel is installed (usr/lib/modules/*-astroos*)" || bad "no usr/lib/modules/*-astroos* tree: the installed kernel is not ours"
    grep -q -- '-cachyos' "$a/kmods" && bad "a CachyOS kernel is installed (usr/lib/modules/*-cachyos*)" || ok "no usr/lib/modules/*-cachyos* tree"
  else
    bad "no usr/lib/modules entry in the squashfs listing (kernel checks could not run)"
  fi
  if [[ "${ASTROOS_WITH_BLACKARCH:-0}" == "1" ]]; then
    missing=()
    while read -r p; do grep -qx "$p" "$a/installed" || missing+=("$p"); done < <(tr -d '\r' < "$here/meta/blackarch.list" | grep -vE '^\s*(#|$)' | awk '{print $1}')
    (( ${#missing[@]} == 0 )) && ok "every blackarch.list package is installed" || bad "BlackArch packages NOT installed: ${missing[*]}"
    # review D-D: repo order settles same-name collisions, but replaces= is
    # honoured from any repo; assert no BlackArch package replaces one we ship
    if curl -sfL "https://blackarch.org/blackarch/blackarch/os/x86_64/blackarch.db" -o "$a/blackarch.db"; then
      bsdtar -xOf "$a/blackarch.db" '*/desc' 2>/dev/null | awk '/^%REPLACES%/{f=1;next} /^$/{f=0} f' | sed 's/[<>=].*//' | sort -u > "$a/ba.replaces"
      local clash; clash=$(comm -12 "$a/ba.replaces" "$a/installed" | tr '\n' ' ')
      if [[ -z "$clash" ]]; then ok "no BlackArch package replaces anything on the ISO"
      else
        # libalpm performs a replaces= only when the replaced package is not
        # available from an earlier repo (measured 2026-09-05: android-tools
        # stayed on extra/ although blackarch/android-sdk-platform-tools
        # replaces it). The verdict is pacman's own -Syu plan with the shipped
        # repo order, not the static field.
        if podman run --rm --pids-limit=-1 -v astroos-pacman-cache:/var/cache/pacman/pkg "$IMG" bash -c '
            set -e
            pacman -Sy --noconfirm '"$clash"' >/dev/null 2>&1
            pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinux >/dev/null 2>&1
            printf "\n[blackarch]\nSigLevel = Never\nServer = https://blackarch.org/blackarch/\$repo/os/\$arch\n" >> /etc/pacman.conf
            pacman -Sy >/dev/null 2>&1
            ! pacman -Syu --print --print-format "%r/%n" 2>/dev/null | grep -q "^blackarch/"' >/dev/null 2>&1; then
          ok "BlackArch replaces= targets stay with their earlier repo under -Syu ($clash)"
        else bad "pacman -Syu would pull BlackArch replacements for: $clash"; fi
      fi
    else bad "blackarch.db unreachable for the replaces check"; fi
  fi

  # installed-system resolution (E2E 2026-09-05): the live ISO carries the real
  # zlib, an installed CachyOS system carries zlib-ng-compat, whose provide is
  # unversioned. geant4's 'zlib>=1.2.3' therefore pulled the real zlib into the
  # Calamares "packages" job and the install died on the conflict, something
  # no check on the ISO's own contents can see. audit-resolver-container.sh
  # runs the installer's own transaction shape (pacman -S --noconfirm --needed
  # over the default selection) on a zlib-ng-compat base with downloads
  # blocked, so prepare-phase errors surface and nothing is installed.
  local mods="$r/etc/calamares/modules"
  if [[ -f "$mods/netinstall.yaml" && -f "$mods/pacstrap.conf" ]]; then
    if podman run --rm --pids-limit=-1 -v "$r/etc/pacman.conf":/iso-pacman.conf:ro -v "$r/etc/pacman.d":/iso-pacman.d:ro \
         -v "$r/usr/share/pacman/keyrings":/iso-keyrings:ro -v "$mods":/iso-modules:ro \
         -v "$here/scripts/audit-resolver-container.sh":/audit-resolver.sh:ro \
         -v astroos-pacman-cache:/var/cache/pacman/pkg "$IMG" bash /audit-resolver.sh > "$a/resolve.out" 2>&1; then
      ok "installed-system resolver: $(tail -1 "$a/resolve.out")"
    else
      bad "installed-system resolver: $(tr '\n' ' ' < "$a/resolve.out" | cut -c1-400)"
    fi
  else
    bad "netinstall.yaml or pacstrap.conf missing from the ISO (resolver simulation skipped)"
  fi
  # bootloader menus
  # grub and syslinux both live under /boot on this profile; a missing search
  # root must not abort the audit through pipefail + set -e (it did: the first
  # two ISO #1 audits died here before their verdict)
  local cfgs; cfgs=$(find "$m/boot" -name '*.cfg' 2>/dev/null | head -40 || true)
  if [[ -n "$cfgs" ]]; then
    # shellcheck disable=SC2086  # the list is intentionally word-split
    grep -l 'AstroOS' $cfgs >/dev/null 2>&1 && ok "bootloader menus say AstroOS" || bad "no AstroOS in bootloader menus"
    # shellcheck disable=SC2086
    grep -h 'menuentry\|MENU LABEL\|MENU TITLE' $cfgs 2>/dev/null | grep -q 'CachyOS' && bad "CachyOS survives in a boot menu title" || ok "no CachyOS in boot menu titles"
  else bad "no bootloader cfg files found in the ISO"; fi
  # unsquashfs recreates the image's directory modes, some unwritable for us
  sudo umount "$m"; chmod -R u+rwX "$a" 2>/dev/null || true; rm -rf "$a" 2>/dev/null || true
  echo "audit: $pass passed, $fail failed" | tee -a "$rep"
  (( fail == 0 )) || die "content audit FAILED ($fail checks)"
  say "audit: PASS ($pass checks)"
}

# --- release: sign + host the ISO ------------------------------------------
stage_release() {
  local iso; iso=$(latest_iso); [[ -n "$iso" ]] || die "no ISO in out/"
  local name; name=$(basename "$iso" .iso)
  # the commit the ISO was BUILT from names the release directory (the tree
  # may have moved on by the time the release stage runs)
  local short; short=$(grep -E '^astroos_commit=' "$out/build-metadata.txt" 2>/dev/null | cut -d= -f2 | cut -c1-7)
  [[ -n "$short" && "$short" != unknown ]] || short=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo nogit)
  [[ -s "$iso_sas_file" ]] || die "no SAS token for the iso container at $iso_sas_file (generate on the laptop: az storage container generate-sas --name $iso_container ...)"
  local sas; sas=$(tr -d '\r\n' < "$iso_sas_file")
  say "release: signing $name.iso with the repo key (armored detached signature, .asc)"
  GNUPGHOME="$keys" gpg --batch --yes --pinentry-mode loopback --passphrase "" --detach-sign --armor \
    -u "$(cat "$keys/FINGERPRINT")" -o "$out/$name.iso.asc" "$iso"
  (cd "$out" && sha256sum "$name.iso" > "$name.iso.sha256")
  # day-granular ISO names: the commit keeps same-day rebuilds apart (review m15)
  local dst="$iso_blob/$name-$short"
  local gate="unknown"
  grep -q 'gate: PASS' "$log" 2>/dev/null && gate="PASS"
  {
    echo "iso=$name.iso"
    echo "bytes=$(stat -c%s "$iso")"
    echo "sha256=$(cut -d' ' -f1 "$out/$name.iso.sha256")"
    echo "signature=$name.iso.asc (detached, armored, key $(cat "$keys/FINGERPRINT"))"
    grep -E '^(builder_image|base_repo|base_commit|astroos_commit|with_aur_repo|with_blackarch|fast)=' "$out/build-metadata.txt"
    echo "repo_db_sha256=$(grep -E '^repo_db_sha256=' "$out/astroos-repo/x86_64/PROMOTION" 2>/dev/null | cut -d= -f2)"
    echo "gate=$gate"
    echo "audit=$(tail -1 "$out/audit.txt" 2>/dev/null)"
    echo "run_start=$run_start"
    echo "released=$(ts)"
    echo "url=$dst/$name.iso"
  } > "$out/RELEASE"
  say "release: uploading manifests, then the ISO, to $dst/"
  local f
  for f in "$name.iso.sha256" "$name.iso.asc" build-metadata.txt manifest.pkglist sha256sums.txt RELEASE audit.txt; do
    [[ -f "$out/$f" ]] || continue
    azcopy copy "$out/$f" "$dst/$f?$sas" --log-level=ERROR >/dev/null
  done
  azcopy copy "$iso" "$dst/$name.iso?$sas" --log-level=ERROR >/dev/null
  printf '%s\n' "$name-$short" > "$out/LATEST"
  azcopy copy "$out/LATEST" "$iso_blob/LATEST?$sas" --log-level=ERROR >/dev/null
  say "release: $dst/$name.iso ($(stat -c%s "$iso") bytes, sha256 $(cut -d' ' -f1 "$out/$name.iso.sha256"))"
}

# --- main -------------------------------------------------------------------
say "forge start: stages=${stages[*]} HEAD=$(git -C "$repo" rev-parse --short HEAD) host=$(hostname) run_start=$run_start"
for s in "${stages[@]}"; do
  cur="$s"; t0=$(date +%s)
  say "## STAGE $s BEGIN"
  "stage_$s"
  mark "$s" "ok $(( $(date +%s) - t0 ))s"
  say "## STAGE $s OK ($(( $(date +%s) - t0 ))s)"
  cur=""
done
say "forge done: ${stages[*]}"
