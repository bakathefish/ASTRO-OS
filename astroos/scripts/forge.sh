#!/usr/bin/env bash
# AstroOS forge: the one-command release pipeline. Runs ON the build VM
# (astroos-forge) from the repo checkout; the laptop driver is
# forge-remote.sh (start VM, sync, run this, collect, deallocate).
#
#   repo     build the signed [astroos] AUR repo (resumable; hours)
#   publish  upload it (packages first, db last: R3 risk #2)
#   verify   prove the HOSTED repo works for a client: db + lock signatures
#            against the SHIPPED keyring, name set == aur.list (D4), and a
#            fresh container installing real packages with SigLevel Required
#   iso      release ISO build with the repo enabled (xz squashfs)
#   gate     QEMU boot gate (five in-guest verdicts, qemu-smoke.sh)
#   audit    content audit INSIDE the artifact: identity, branding, repo
#            wiring, and every AUR-lane package actually installed
#   release  sign the ISO with the repo key, upload ISO + sums + signature +
#            manifests to the public container, write out/RELEASE
#
# Stages run in the order given (default: all, in that order). The first
# failure stops the run with "## STAGE <name> FAIL" in out/forge.log and a
# non-zero exit; every stage is idempotent, so a rerun after the fix picks
# up at the failed stage. Deallocating is the laptop's job: a VM cannot
# deallocate itself, and a guest shutdown still bills.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"    # astroos/
repo="$(cd "$here/.." && pwd)"
out="$repo/out"
log="$out/forge.log"
status="$out/forge.status"
account="${ASTROOS_REPO_ACCOUNT:-astroosrepo}"
container="${ASTROOS_REPO_CONTAINER:-repo}"
keys="${ASTROOS_REPO_KEYS:-$HOME/astroos-repo-keys}"
sas_file="${ASTROOS_REPO_SAS:-$HOME/astroos-repo.sas}"
IMG="${ASTROOS_BUILDER_IMAGE:-docker.io/archlinux:base-devel}"
blob="https://${account}.blob.core.windows.net/${container}"
repo_url="$blob/astroos/x86_64"
export ASTROOS_WITH_AUR_REPO="${ASTROOS_WITH_AUR_REPO:-1}"

stages=("$@")
(( ${#stages[@]} )) || stages=(repo publish verify iso gate audit release)

mkdir -p "$out"
ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
say()  { echo "[$(ts)] $*" | tee -a "$log"; }
mark() { echo "$(ts) $1 $2" >> "$status"; }
die()  { say "!! $*"; exit 1; }
scope_names() { tr -d '\r' < "$here/meta/aur.list" | grep -vE '^\s*(#|$)' | awk '{print $1}' | sort; }
db_names()    { bsdtar -tf "$1" | awk -F/ '$2=="desc"{print $1}' | sed 's/-[^-]*-[^-]*$//' | sort -u; }
latest_iso()  { ls -1t "$out"/*.iso 2>/dev/null | head -1; }

cur=""
# shellcheck disable=SC2154  # rc is assigned inside the trap string
trap 'rc=$?; if [[ $rc -ne 0 && -n "$cur" ]]; then mark "$cur" FAIL; say "## STAGE $cur FAIL (rc=$rc)"; fi' EXIT

# --- repo / publish: the ratified lane script -------------------------------
stage_repo()    { bash "$here/scripts/build-aur-repo.sh" build   2>&1 | tee -a "$log" | grep -E '^(>>|!!)' || true; [[ ${PIPESTATUS[0]} -eq 0 ]] || die "repo build failed (see $log)"; }
stage_publish() { bash "$here/scripts/build-aur-repo.sh" publish 2>&1 | tee -a "$log" | grep -E '^(>>|!!)' || true; [[ ${PIPESTATUS[0]} -eq 0 ]] || die "publish failed (see $log)"; }

# --- verify: the HOSTED repo, as a client sees it ---------------------------
stage_verify() {
  local v; v=$(mktemp -d)
  local kr="$here/overlay/airootfs/usr/share/pacman/keyrings/astroos.gpg"
  local fpr; fpr=$(tr -d ' \r\n' < "$here/branding/REPO_FINGERPRINT")
  say "verify: fetching hosted db, files, lock + signatures from $repo_url"
  local f
  for f in astroos.db astroos.db.sig astroos.files astroos.files.sig aur-map.lock aur-map.lock.sig aur-map.lock.sha256; do
    curl -sfL "$repo_url/$f" -o "$v/$f" || die "hosted $f unreachable"
  done
  # 1. signatures verify against the SHIPPED keyring (exactly what clients trust)
  gpg --batch --no-default-keyring --keyring "$v/kr.gpg" --import "$kr" >/dev/null 2>&1
  for f in astroos.db astroos.files aur-map.lock; do
    gpg --batch --no-default-keyring --keyring "$v/kr.gpg" --verify "$v/$f.sig" "$v/$f" >/dev/null 2>"$v/gpg.err" \
      || die "hosted $f signature does NOT verify with the shipped keyring: $(tr '\n' ' ' < "$v/gpg.err")"
  done
  [[ "$(sha256sum "$v/aur-map.lock" | awk '{print $1}')" == "$(tr -d ' \r\n' < "$v/aur-map.lock.sha256")" ]] \
    || die "hosted aur-map.lock sha256 mismatch"
  say "verify: db, files and lock signatures OK against the shipped keyring $fpr"
  # 2. name set == aur.list, the same D4 check container-build.sh performs
  local want have
  want=$(scope_names); have=$(db_names "$v/astroos.db")
  if [[ "$want" != "$have" ]]; then
    diff <(echo "$want") <(echo "$have") | tee -a "$log" || true
    die "hosted db name set != aur.list (D4)"
  fi
  say "verify: hosted db carries exactly the $(echo "$have" | wc -l) aur.list names"
  # 3. a fresh client resolves every name and installs real packages under SigLevel Required
  local names; names=$(echo "$want" | tr '\n' ' ')
  podman run --rm --pids-limit=-1 -v "$kr":/astroos.gpg:ro -v astroos-pacman-cache:/var/cache/pacman/pkg "$IMG" bash -c '
    set -e
    pacman-key --init >/dev/null 2>&1
    pacman-key --add /astroos.gpg >/dev/null 2>&1
    pacman-key --lsign-key '"$fpr"' >/dev/null 2>&1
    printf "\n[astroos]\nSigLevel = Required DatabaseOptional\nServer = '"$repo_url"'\n" >> /etc/pacman.conf
    pacman -Sy >/dev/null
    pacman -Sp --noconfirm '"$names"' >/dev/null
    pacman -S --noconfirm siril-git ds9-bin opendrop python-healpy astromatic-swarp >/dev/null
    pacman -Q siril-git ds9-bin opendrop python-healpy astromatic-swarp' 2>&1 | tee -a "$log" \
    || die "client install test against the hosted repo FAILED"
  say "verify: fresh client resolved all $(echo "$have" | wc -l) names and installed 5 packages with signature verification"
  rm -rf "$v"
}

# --- iso / gate -------------------------------------------------------------
stage_iso() {
  say "iso: release build (ASTROOS_WITH_AUR_REPO=$ASTROOS_WITH_AUR_REPO ASTROOS_WITH_BLACKARCH=${ASTROOS_WITH_BLACKARCH:-0} ASTROOS_FAST=${ASTROOS_FAST:-0})"
  # shellcheck disable=SC2024  # the log is meant to be written as the invoking user, not root
  sudo env ASTROOS_WITH_AUR_REPO="$ASTROOS_WITH_AUR_REPO" ASTROOS_WITH_BLACKARCH="${ASTROOS_WITH_BLACKARCH:-0}" \
           ASTROOS_FAST="${ASTROOS_FAST:-0}" ASTROOS_SIZE_BUDGET_GIB="${ASTROOS_SIZE_BUDGET_GIB:-7}" \
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
  local sfs="$m/arch/x86_64/airootfs.sfs"; [[ -f "$sfs" ]] || die "airootfs.sfs missing in ISO"
  local fail=0 pass=0 rep="$out/audit.txt"
  : > "$rep"
  ok()  { echo "  [ok] $1" | tee -a "$rep"; pass=$((pass+1)); }
  bad() { echo "  [FAIL] $1" | tee -a "$rep"; fail=$((fail+1)); }
  echo "AstroOS content audit: $(basename "$iso") $(ts)" | tee -a "$rep"
  # files of interest, extracted without unpacking the whole image
  unsquashfs -q -n -d "$a/root" "$sfs" etc/os-release usr/lib/os-release etc/lsb-release etc/issue \
    etc/pacman.conf etc/pacman.d/hooks etc/fastfetch usr/share/astroos usr/share/pacman/keyrings \
    usr/share/plymouth/themes/spinner/watermark.png usr/local/bin/astroos-doctor >/dev/null 2>&1 || true
  local r="$a/root"
  grep -q '^NAME="AstroOS"' "$r/etc/os-release" 2>/dev/null && ok "etc/os-release NAME=AstroOS" || bad "etc/os-release is not AstroOS"
  grep -q '^NAME="AstroOS"' "$r/usr/lib/os-release" 2>/dev/null && ok "usr/lib/os-release NAME=AstroOS" || bad "usr/lib/os-release is not AstroOS"
  grep -qi cachyos "$r/etc/os-release" "$r/etc/lsb-release" 2>/dev/null && bad "CachyOS string survives in identity files" || ok "no CachyOS string in identity files"
  grep -q '^DISTRIB_ID=AstroOS' "$r/etc/lsb-release" 2>/dev/null && ok "lsb-release DISTRIB_ID=AstroOS" || bad "lsb-release not AstroOS"
  grep -q AstroOS "$r/etc/issue" 2>/dev/null && ok "/etc/issue branded" || bad "/etc/issue not branded"
  [[ "$(sha256sum "$r/usr/share/plymouth/themes/spinner/watermark.png" 2>/dev/null | cut -d' ' -f1)" == "$(sha256sum "$here/branding/out/watermark.png" | cut -d' ' -f1)" ]] \
    && ok "plymouth watermark is the AstroOS asset" || bad "plymouth watermark is not ours"
  [[ -s "$r/etc/fastfetch/astroos-logo.ansi" ]] && ok "fastfetch ANSI logo shipped" || bad "fastfetch logo missing"
  [[ -x "$r/usr/local/bin/astroos-doctor" ]] && ok "astroos-doctor executable" || bad "astroos-doctor missing or not executable"
  [[ -f "$r/etc/pacman.d/hooks/zz-astroos-identity.hook" ]] && ok "identity hook shipped" || bad "identity hook missing"
  [[ "$(readlink "$r/etc/pacman.d/hooks/cachyos-branding.hook" 2>/dev/null)" == "/dev/null" ]] && ok "cachyos-branding hook masked" || bad "cachyos-branding hook NOT masked"
  if [[ "$ASTROOS_WITH_AUR_REPO" == "1" ]]; then
    grep -q '^\[astroos\]' "$r/etc/pacman.conf" 2>/dev/null && ok "[astroos] repo in shipped pacman.conf" || bad "[astroos] missing from shipped pacman.conf"
    local shipfpr; shipfpr=$(gpg --show-keys --with-colons "$r/usr/share/pacman/keyrings/astroos.gpg" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
    [[ "$shipfpr" == "$(tr -d ' \r\n' < "$here/branding/REPO_FINGERPRINT")" ]] && ok "shipped astroos keyring fingerprint matches" || bad "shipped keyring fingerprint mismatch ($shipfpr)"
  fi
  if [[ "${ASTROOS_WITH_BLACKARCH:-0}" == "1" ]]; then
    grep -q '^\[blackarch\]' "$r/etc/pacman.conf" 2>/dev/null && ok "[blackarch] repo in shipped pacman.conf" || bad "[blackarch] missing from shipped pacman.conf"
    [[ -s "$r/usr/share/pacman/keyrings/blackarch.gpg" ]] && ok "blackarch keyring shipped" || bad "blackarch keyring missing"
  fi
  # installed package set from the pacman local db inside the squashfs
  unsquashfs -l "$sfs" 2>/dev/null | grep -oE 'var/lib/pacman/local/[^/]+$' | sed 's|.*/||; s/-[^-]*-[^-]*$//' | sort -u > "$a/installed"
  local n_inst; n_inst=$(wc -l < "$a/installed")
  echo "  installed packages: $n_inst" | tee -a "$rep"
  local missing=()
  if [[ "$ASTROOS_WITH_AUR_REPO" == "1" ]]; then
    while read -r p; do grep -qx "$p" "$a/installed" || missing+=("$p"); done < <(scope_names)
    (( ${#missing[@]} == 0 )) && ok "every aur.list package is installed in the image" || bad "AUR-lane packages NOT installed: ${missing[*]}"
  fi
  missing=()
  while read -r p; do grep -qx "$p" "$a/installed" || missing+=("$p"); done < <(grep -vE '^\s*(#|$)' "$here/astroos-additions.x86_64" | tr -d '\r')
  (( ${#missing[@]} == 0 )) && ok "every AstroOS addition is installed" || bad "additions NOT installed: ${missing[*]}"
  # bootloader menus
  local cfgs; cfgs=$(find "$m/boot" "$m/syslinux" -name '*.cfg' 2>/dev/null | head -20)
  grep -l 'AstroOS' $cfgs >/dev/null 2>&1 && ok "bootloader menus say AstroOS" || bad "no AstroOS in bootloader menus"
  grep -h 'menuentry\|MENU LABEL\|MENU TITLE' $cfgs 2>/dev/null | grep -q 'CachyOS' && bad "CachyOS survives in a boot menu title" || ok "no CachyOS in boot menu titles"
  sudo umount "$m"; rm -rf "$a"
  echo "audit: $pass passed, $fail failed" | tee -a "$rep"
  (( fail == 0 )) || die "content audit FAILED ($fail checks)"
  say "audit: PASS ($pass checks)"
}

# --- release: sign + host the ISO ------------------------------------------
stage_release() {
  local iso; iso=$(latest_iso); [[ -n "$iso" ]] || die "no ISO in out/"
  local name; name=$(basename "$iso" .iso)
  [[ -s "$sas_file" ]] || die "no SAS token at $sas_file"
  local sas; sas=$(tr -d '\r\n' < "$sas_file")
  say "release: signing $name.iso with the repo key"
  GNUPGHOME="$keys" gpg --batch --yes --pinentry-mode loopback --passphrase "" --detach-sign --armor \
    -u "$(cat "$keys/FINGERPRINT")" -o "$out/$name.iso.sig" "$iso"
  (cd "$out" && sha256sum "$name.iso" > "$name.iso.sha256")
  local dst="$blob/iso/$name"
  {
    echo "iso=$name.iso"
    echo "bytes=$(stat -c%s "$iso")"
    echo "sha256=$(cut -d' ' -f1 "$out/$name.iso.sha256")"
    echo "signature=$name.iso.sig (detached, armored, key $(cat "$keys/FINGERPRINT"))"
    grep -E '^(builder_image|base_repo|base_commit|astroos_commit)=' "$out/build-metadata.txt"
    echo "repo_db_sha256=$(grep -E '^repo_db_sha256=' "$out/astroos-repo/x86_64/PROMOTION" 2>/dev/null | cut -d= -f2)"
    echo "gate=$(grep -q 'SMOKE TEST PASS' "$out/qemu-smoke.log" 2>/dev/null && echo PASS || echo unknown)"
    echo "audit=$(tail -1 "$out/audit.txt" 2>/dev/null)"
    echo "released=$(ts)"
    echo "url=$dst/$name.iso"
  } > "$out/RELEASE"
  say "release: uploading manifests, then the ISO, to $dst/"
  local f
  for f in "$name.iso.sha256" "$name.iso.sig" build-metadata.txt manifest.pkglist sha256sums.txt RELEASE audit.txt qemu-smoke.log; do
    [[ -f "$out/$f" ]] || continue
    azcopy copy "$out/$f" "$dst/$f?$sas" --log-level=ERROR >/dev/null
  done
  azcopy copy "$iso" "$dst/$name.iso?$sas" --log-level=ERROR >/dev/null
  printf '%s\n' "$name" > "$out/LATEST"
  azcopy copy "$out/LATEST" "$blob/iso/LATEST?$sas" --log-level=ERROR >/dev/null
  say "release: $dst/$name.iso ($(stat -c%s "$iso") bytes, sha256 $(cut -d' ' -f1 "$out/$name.iso.sha256"))"
}

# --- main -------------------------------------------------------------------
say "forge start: stages=${stages[*]} HEAD=$(git -C "$repo" rev-parse --short HEAD) host=$(hostname)"
for s in "${stages[@]}"; do
  case "$s" in repo|publish|verify|iso|gate|audit|release) ;; *) die "unknown stage: $s" ;; esac
  cur="$s"; t0=$(date +%s)
  say "## STAGE $s BEGIN"
  "stage_$s"
  mark "$s" "ok $(( $(date +%s) - t0 ))s"
  say "## STAGE $s OK ($(( $(date +%s) - t0 ))s)"
  cur=""
done
say "forge done: ${stages[*]}"
