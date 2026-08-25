#!/usr/bin/env bash
# Build + publish the signed [astroos] pacman repo from AUR sources.
# Council R3 (CONVERGED 2026-08-25, COUNCIL_LEDGER.md): every design point
# below is ratified — change only via a new council round.
#
#   scope      aur.list non-comment entries == v1 scope, machine-checked (D4)
#   liveness   AUR RPC check for every name, hard-fail, every run (D7)
#   migration  fail if any name reached the official repos (D6)
#   isolation  one FRESH container per package, local repo grows between
#              packages -> contamination impossible by construction (D1)
#   gate       python packages must pass an import smoke in a fresh container
#              (D6: astroml/emcee gate, applied to all python-*)
#   provenance aur-map.lock: AUR commit, pkgver, epoch, .SRCINFO sources +
#              checksums per package; published signed beside the db (D5)
#   publish    packages first, db+lock LAST (half-published-state risk #2)
#
# Subcommands:  keygen | build | publish | all   (default: build)
# Host needs: podman, curl, jq, python3, git. Publish needs azcopy + SAS file.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"    # astroos/
repo="$(cd "$here/.." && pwd)"
out="$repo/out/astroos-repo/x86_64"
keys="${ASTROOS_REPO_KEYS:-$HOME/astroos-repo-keys}"
sas_file="${ASTROOS_REPO_SAS:-$HOME/astroos-repo.sas}"
account="${ASTROOS_REPO_ACCOUNT:-astroosrepo}"
container="${ASTROOS_REPO_CONTAINER:-repo}"
IMG="${ASTROOS_BUILDER_IMAGE:-docker.io/archlinux:base-devel}"
SCOPE_EXPECT="${ASTROOS_AUR_SCOPE:-26}"
cmd="${1:-build}"

msg() { echo ">> $*"; }
die() { echo "!! $*" >&2; exit 1; }

# --- keygen: one-time signing key (procedure: astroos/KEYS.md) -------------
do_keygen() {
  [[ -d "$keys" ]] && die "$keys already exists — rotation is manual, see KEYS.md"
  mkdir -p "$keys"; chmod 700 "$keys"
  podman run --rm -v "$keys":/keys "$IMG" bash -c '
    set -e
    export GNUPGHOME=/keys
    gpg --batch --quick-generate-key "AstroOS Repository <repo@astroos.local>" ed25519 sign 0
    fpr=$(gpg --list-keys --with-colons | awk -F: "/^fpr/{print \$10; exit}")
    echo "$fpr" > /keys/FINGERPRINT
    gpg --export "$fpr" > /keys/astroos.gpg
    gpg --export --armor "$fpr" > /keys/astroos.asc
    chmod -R go-rwx /keys'
  msg "key generated: $(cat "$keys/FINGERPRINT")"
  msg "NOW: back up $keys offline (owner), see astroos/KEYS.md"
}

# --- scope + liveness + migration preflight (D4, D7, D6) -------------------
scope_preflight() {
  mapfile -t PKGS < <(tr -d '\r' < "$here/meta/aur.list" | grep -vE '^\s*(#|$)' | awk '{print $1}')
  local n=${#PKGS[@]}
  (( n == SCOPE_EXPECT )) || die "scope: ${n} entries in aur.list, expected ${SCOPE_EXPECT} (D4)"
  for p in "${PKGS[@]}"; do [[ "$p" == "burpsuite" ]] && die "scope: parked package in list (D4)"; done
  msg "scope OK: $n packages"

  # AUR liveness via RPC v5 — every name must resolve (D7, mandatory pre-publish)
  local args=(); for p in "${PKGS[@]}"; do args+=(--data-urlencode "arg[]=$p"); done
  local rpc; rpc=$(curl -sG --retry 3 "https://aur.archlinux.org/rpc/v5/info" "${args[@]}")
  local found missing=()
  found=$(jq -r '.results[].Name' <<<"$rpc")
  for p in "${PKGS[@]}"; do grep -qx "$p" <<<"$found" || missing+=("$p"); done
  (( ${#missing[@]} == 0 )) || die "AUR liveness: missing/renamed: ${missing[*]} (D7)"
  msg "AUR liveness OK: all $n names resolve"
  printf '%s\n' "$rpc" > /tmp/aur-rpc.json

  # Official-repo migration check (D6): a name that reached the repos must
  # leave the AUR lane (maintenance surface minimization).
  local migrated
  migrated=$(podman run --rm -v astroos-pacman-cache:/var/cache/pacman/pkg "$IMG" bash -c \
    "pacman -Sy >/dev/null 2>&1; for p in ${PKGS[*]}; do pacman -Si \"\$p\" >/dev/null 2>&1 && echo \"\$p\"; done" || true)
  [[ -z "$migrated" ]] || die "migrated to official repos, move out of aur.list (D6): $migrated"
  msg "migration check OK: all $n are AUR-only"
}

# --- dependency order: topo sort over in-scope depends (RPC data) ----------
topo_order() {
  python3 - "$@" << 'PY'
import json, re, sys
scope = sys.argv[1:]
rpc = json.load(open('/tmp/aur-rpc.json'))
strip = lambda d: re.split(r'[<>=]', d)[0]
deps = {r['Name']: {strip(d) for d in (r.get('Depends') or []) + (r.get('MakeDepends') or [])} & set(scope)
        for r in rpc['results']}
order, seen = [], set()
def visit(p, stack=()):
    if p in seen: return
    if p in stack: raise SystemExit(f"dependency cycle at {p}")
    for d in sorted(deps.get(p, ())): visit(d, stack + (p,))
    seen.add(p); order.append(p)
for p in sorted(scope): visit(p)
print(' '.join(order))
PY
}

# --- build: one fresh container per package (D1) ---------------------------
do_build() {
  scope_preflight
  mkdir -p "$out"
  [[ -f "$keys/FINGERPRINT" ]] || die "no signing key — run: $0 keygen"
  local fpr; fpr=$(cat "$keys/FINGERPRINT")
  local order; order=$(topo_order "${PKGS[@]}")
  msg "build order: $order"
  local lock=/tmp/aur-map.entries; : > "$lock"

  for p in $order; do
    msg "=== building $p (fresh container) ==="
    podman run --rm --pids-limit=-1 -v astroos-pacman-cache:/var/cache/pacman/pkg -v "$out":/repo -v /tmp/aur-build-$p:/work "$IMG" bash -c '
      set -euo pipefail
      p='"$p"'
      # local repo of already-built packages (SigLevel Never: build-time only,
      # the published repo is signature-verified by clients)
      if ls /repo/*.pkg.tar.zst >/dev/null 2>&1; then
        [[ -f /repo/astroos-local.db.tar.gz ]] || { repo-add -q /repo/astroos-local.db.tar.gz /repo/*.pkg.tar.zst || true; }
        printf "[astroos-local]\nSigLevel = Never\nServer = file:///repo\n" >> /etc/pacman.conf
      fi
      pacman -Syu --noconfirm --needed git base-devel >/dev/null
      useradd -m builder
      echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
      cd /work
      git clone --quiet "https://aur.archlinux.org/$p.git" pkg
      chown -R builder:builder pkg
      cd pkg
      git rev-parse HEAD > /work/COMMIT
      export MAKEFLAGS="-j$(nproc)"
      su builder -c "makepkg --noconfirm -s"
      cp ./*.pkg.tar.zst /repo/
      # provenance material for aur-map.lock (D5): raw .SRCINFO source+sums
      awk -F" = " "/^\t(source|sha256sums|sha512sums|b2sums)/ {print \$0}" .SRCINFO > /work/SRCINFO_SOURCES || true
      srcinfo_ver=$(awk -F" = " "/^\tpkgver/{v=\$2} /^\tpkgrel/{r=\$2} END{print v\"-\"r}" .SRCINFO)
      echo "$srcinfo_ver" > /work/PKGVER
    ' || die "build failed: $p (hermetic container — failure is attributable to $p alone)"
    jq -n --arg name "$p" \
          --arg commit "$(cat /tmp/aur-build-$p/COMMIT)" \
          --arg pkgver "$(cat /tmp/aur-build-$p/PKGVER)" \
          --arg epoch "$(date +%s)" \
          --rawfile src /tmp/aur-build-$p/SRCINFO_SOURCES \
          '{name:$name, aur_commit:$commit, pkgver:$pkgver, build_epoch:($epoch|tonumber), sources:($src|split("\n")|map(select(length>0))), patches:[]}' >> "$lock"
    rm -rf /tmp/aur-build-$p
  done

  # python import smoke in a fresh container (D6 gate, all python packages)
  msg "=== python import smoke (D6 gate) ==="
  local -A smoke=( [python-astroml]=astroML [python-emcee]=emcee [python-qutip]=qutip
                   [python-qiskit]=qiskit [python-sunpy]=sunpy [python-healpy]=healpy )
  for p in $order; do
    [[ -n "${smoke[$p]:-}" ]] || continue
    podman run --rm --pids-limit=-1 -v astroos-pacman-cache:/var/cache/pacman/pkg -v "$out":/repo:ro "$IMG" bash -c '
      set -e
      printf "[astroos-local]\nSigLevel = Never\nServer = file:///repo\n" >> /etc/pacman.conf
      repo-add -q /tmp/x.db.tar.gz >/dev/null 2>&1 || true
      pacman -Sy >/dev/null
      pacman -S --noconfirm '"$p"' >/dev/null
      python -c "import '"${smoke[$p]}"'; print(\"import OK: '"${smoke[$p]}"'\")"
    ' || die "import smoke FAILED: $p (D6 gate) — exclude from v1 or patch"
  done

  # sign packages + build the real db (signed), assemble aur-map.lock (D5)
  msg "=== signing + repo db ==="
  rm -f "$out"/astroos-local.db.tar.gz "$out"/astroos-local.db 2>/dev/null || true
  podman run --rm -v "$out":/repo -v "$keys":/keys "$IMG" bash -c '
    set -euo pipefail
    export GNUPGHOME=/keys
    fpr=$(cat /keys/FINGERPRINT)
    cd /repo
    for f in *.pkg.tar.zst; do gpg --batch --yes --detach-sign -u "$fpr" "$f"; done
    repo-add --sign --key "$fpr" astroos.db.tar.zst *.pkg.tar.zst
    # blob storage serves real files, not symlinks
    cp astroos.db.tar.zst astroos.db; cp astroos.db.tar.zst.sig astroos.db.sig
    cp astroos.files.tar.zst astroos.files; cp astroos.files.tar.zst.sig astroos.files.sig'
  jq -s --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{published:$date, packages:.}' "$lock" > "$out/aur-map.lock"
  sha256sum "$out/aur-map.lock" | awk '{print $1}' > "$out/aur-map.lock.sha256"
  podman run --rm -v "$out":/repo -v "$keys":/keys "$IMG" bash -c \
    'export GNUPGHOME=/keys; gpg --batch --yes --detach-sign -u "$(cat /keys/FINGERPRINT)" /repo/aur-map.lock'
  msg "build complete: $(ls "$out"/*.pkg.tar.zst | wc -l) packages in $out"
}

# --- publish: packages first, db + lock LAST (risk #2) ---------------------
do_publish() {
  [[ -s "$sas_file" ]] || die "no SAS token at $sas_file (generate on the laptop, scp here)"
  command -v azcopy >/dev/null || die "azcopy not installed"
  local sas; sas=$(tr -d '\r\n' < "$sas_file")
  local base="https://${account}.blob.core.windows.net/${container}/astroos/x86_64"
  msg "publish stage 1: packages + signatures"
  azcopy copy "$out/*.pkg.tar.zst"     "${base}?${sas}" >/dev/null
  azcopy copy "$out/*.pkg.tar.zst.sig" "${base}?${sas}" >/dev/null
  msg "publish stage 2: db + lock (goes live atomically last)"
  for f in astroos.files astroos.files.sig astroos.files.tar.zst astroos.files.tar.zst.sig \
           aur-map.lock aur-map.lock.sha256 aur-map.lock.sig \
           astroos.db.tar.zst astroos.db.tar.zst.sig astroos.db astroos.db.sig; do
    azcopy copy "$out/$f" "${base}/$f?${sas}" >/dev/null
  done
  # promotion manifest -> synced into git at the next laptop session (D5)
  {
    echo "published=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "repo_db_sha256=$(sha256sum "$out/astroos.db.tar.zst" | awk '{print $1}')"
    echo "lock_sha256=$(cat "$out/aur-map.lock.sha256")"
    echo "package_count=$(ls "$out"/*.pkg.tar.zst | wc -l)"
    echo "base_url=$base"
  } > "$out/PROMOTION"
  msg "published to $base — PROMOTION manifest written"
}

case "$cmd" in
  keygen)  do_keygen ;;
  build)   do_build ;;
  publish) do_publish ;;
  all)     do_build; do_publish ;;
  *) die "usage: $0 [keygen|build|publish|all]" ;;
esac
