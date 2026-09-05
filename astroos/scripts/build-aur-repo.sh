#!/usr/bin/env bash
# Build + publish the signed [astroos] pacman repo: AUR sources (meta/aur.list)
# plus the AstroOS local packages (pkgs/<name>/PKGBUILD).
# Council R3 (CONVERGED 2026-08-25, COUNCIL_LEDGER.md): every design point
# below is ratified — change only via a new council round. R4 (2026-09-05)
# added the local lane and the review fixes (M4, M5, m7, m8, m9, B1).
#
#   scope      aur.list non-comment entries == v1 AUR scope, machine-checked
#              (D4); the repo db carries exactly aur.list ∪ pkgs/ names
#   liveness   AUR RPC check for every name, hard-fail, every run (D7)
#   migration  fail if any name reached the official repos (D6), asked of
#              archlinux.org directly (no container, no vacuous pass)
#   isolation  one FRESH container per package, local repo grows between
#              packages -> contamination impossible by construction (D1)
#   gate       python packages must pass an import smoke in a fresh container
#              (D6: astroml/emcee gate, applied to all python-*)
#   provenance aur-map.lock: AUR commit, pkgver AS BUILT, upstream VCS commit
#              for -git packages, pre-patch .SRCINFO sources, applied patches;
#              local packages: the commit that last touched their inputs (D5)
#   publish    packages first, db+lock LAST; refused while any failure is on
#              record (risk #2, review B1)
#
# Local lane (pkgs/<name>/): the AstroOS identity, tools, installer config and
# laptop packages that must reach INSTALLED systems (the installer pacstraps
# from repos; the live overlay never lands on disk: R4 branding survey §0).
# Same container discipline; version = UTC date.time of the commit that last
# touched the package's inputs (its directory + the paths in pkgs/<name>/inputs),
# so an unchanged package keeps its version and is skipped.
#
# Subcommands:  keygen | preflight | build | local <name> | publish | all
# Host needs: podman, curl, jq, python3, git. Publish needs azcopy + SAS file.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"    # astroos/
repo="$(cd "$here/.." && pwd)"
out="$repo/out/astroos-repo/x86_64"
locks="$repo/out/astroos-repo/locks"
keys="${ASTROOS_REPO_KEYS:-$HOME/astroos-repo-keys}"
sas_file="${ASTROOS_REPO_SAS:-$HOME/astroos-repo.sas}"
account="${ASTROOS_REPO_ACCOUNT:-astroosrepo}"
container="${ASTROOS_REPO_CONTAINER:-repo}"
IMG="${ASTROOS_BUILDER_IMAGE:-docker.io/archlinux:base-devel}"
# 36 at R3.1; 35 on 2026-09-05 (informant reached [extra], D6 migration rule);
# 33 the same day: python-parfive's docs-only makedepends (sphinx-automodapi,
# sphinx_contributors) left with the docs build (aur-patches/python-parfive);
# 32: python-pytest-runner left with opendrop's check() (aur-patches/opendrop).
SCOPE_EXPECT="${ASTROOS_AUR_SCOPE:-32}"
cmd="${1:-build}"
arg="${2:-}"

msg() { echo ">> $*"; }
die() { echo "!! $*" >&2; exit 1; }

# Local packages: every pkgs/<name>/PKGBUILD.
local_names() { local d; for d in "$here"/pkgs/*/; do [[ -f "$d/PKGBUILD" ]] && basename "$d"; done; return 0; }

# --- keygen: one-time signing key (procedure: astroos/KEYS.md) -------------
do_keygen() {
  [[ -d "$keys" ]] && die "$keys already exists — rotation is manual, see KEYS.md"
  mkdir -p "$keys"; chmod 700 "$keys"
  podman run --rm -v "$keys":/keys "$IMG" bash -c '
    set -e
    export GNUPGHOME=/keys
    # loopback + empty passphrase: no tty in the container for pinentry; the
    # key is protected by fs perms + the owner offline backup (KEYS.md)
    gpg --batch --pinentry-mode loopback --passphrase "" \
        --quick-generate-key "AstroOS Repository <repo@astroos.local>" ed25519 sign 0
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
  msg "scope OK: $n AUR packages"

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
  # leave the AUR lane (maintenance surface minimization). Asked of
  # archlinux.org's package search (exact name match); an unreachable API is a
  # failure, never a pass (review M4: the old container check passed
  # vacuously whenever podman/docker.io failed).
  local migrated=() hit
  for p in "${PKGS[@]}"; do
    hit=$(curl -sfG --retry 3 "https://archlinux.org/packages/search/json/" --data-urlencode "name=$p" \
          | jq -r '.results[] | "\(.repo)/\(.pkgname)"' | sort -u | tr '\n' ' ') \
      || die "migration check: archlinux.org unreachable for $p (D6 needs a verdict, not a guess)"
    [[ -z "$hit" ]] || migrated+=("$p -> $hit")
  done
  (( ${#migrated[@]} == 0 )) || die "migrated to official repos, move out of aur.list (D6): ${migrated[*]}"
  msg "migration check OK: all $n are AUR-only"

  mapfile -t LOCALS < <(local_names)
  msg "local packages: ${#LOCALS[@]} (${LOCALS[*]:-none})"
}

# --- dependency order: topo sort over in-scope depends (RPC data) ----------
topo_order() {
  python3 - "$@" << 'PY'
import json, re, sys
scope = sys.argv[1:]
rpc = json.load(open('/tmp/aur-rpc.json'))
strip = lambda d: re.split(r'[<>=]', d)[0]
# Resolve dependency NAMES to in-scope PACKAGES through Provides (opendrop
# depends on "owlink", provided by owlink-git), and include CheckDepends:
# makepkg -s installs them too (python-aioftp's tests need python-siosocks).
# Run 2 (2026-09-05) failed both packages on ordering for exactly these reasons.
prov = {}
for r in rpc['results']:
    prov[r['Name']] = r['Name']
    for pv in (r.get('Provides') or []):
        prov.setdefault(strip(pv), r['Name'])
deps = {}
for r in rpc['results']:
    ds = (r.get('Depends') or []) + (r.get('MakeDepends') or []) + (r.get('CheckDepends') or [])
    deps[r['Name']] = {prov[strip(d)] for d in ds if strip(d) in prov} - {r['Name']}
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

# --- artifact naming helpers ------------------------------------------------
# pkgname from a package filename: name-ver-rel-arch.pkg.tar.zst has exactly
# three trailing dash-fields (pkgver never contains "-", epochs and -git
# pkgvers included), so stripping three suffixes yields the exact pkgname.
# Package files in out/: ANY package extension (.pkg.tar.zst by default, but
# a PKGBUILD may override PKGEXT — geant4 does), never the detached .sig files.
pkg_files() { find "$out" -maxdepth 1 -name '*.pkg.tar*' ! -name '*.sig' | sort; }
pkgname_of() { local n; n=$(basename "$1"); n=${n%%.pkg.tar*}; n=${n%-*}; n=${n%-*}; n=${n%-*}; echo "$n"; }
# "pkgver-pkgrel" as built, from the filename (review M5: .SRCINFO is wrong
# for VCS packages)
pkgver_of() { local n; n=$(basename "$1"); n=${n%%.pkg.tar*}; n=${n%-*}; echo "${n#"$(pkgname_of "$1")-"}"; }

# The repo file that belongs to pkgname $1 EXACTLY. A split sibling
# (python-parfive-doc) or a -debug leftover shares the prefix but never the
# pkgname, and a -git pkgver (r45.da255a7) is not "[0-9]*" — both fooled the
# old glob check.
own_pkg_file() {
  local f
  while read -r f; do
    [[ "$(pkgname_of "$f")" == "$1" ]] && { echo "$f"; return 0; }
  done < <(pkg_files)
  return 1
}

# --- D6 import smoke --------------------------------------------------------
# Install the built python package from the local repo in a FRESH container
# and import its module. A failure is RECORDED, not fatal at that moment (the
# rest of the scope still banks); do_build refuses to sign while any failure
# is on record. Runs right after each build so a stale package surfaces in
# minutes, not after the two-hour geant4 build.
declare -A SMOKE=( [python-astroml]=astroML [python-emcee]=emcee [python-qutip]=qutip
                   [python-qiskit]=qiskit [python-sunpy]=sunpy [python-healpy]=healpy )
smoke_check() {
  local p="$1" mod="${SMOKE[$1]:-}"
  [[ -n "$mod" ]] || return 0
  msg "=== import smoke: $p -> import $mod (D6 gate) ==="
  if podman run --rm --pids-limit=-1 -v astroos-pacman-cache:/var/cache/pacman/pkg -v "$out":/repo "$IMG" bash -c '
      set -e
      # fresh local db so the package built seconds ago is resolvable
      cd /repo && rm -f astroos-local.* && repo-add -q astroos-local.db.tar.gz $(find . -maxdepth 1 -name "*.pkg.tar*" ! -name "*.sig" | sort) >/dev/null 2>&1
      printf "[astroos-local]\nSigLevel = Never\nServer = file:///repo\n" >> /etc/pacman.conf
      pacman -Sy >/dev/null
      pacman -S --noconfirm '"$p"' >/dev/null
      python -c "import '"$mod"'; print(\"import OK: '"$mod"'\")"'; then
    [[ -f "$locks/SMOKE_FAIL" ]] && sed -i "/^$p\$/d" "$locks/SMOKE_FAIL"
    return 0
  fi
  echo "!! import smoke FAILED: $p (recorded; signing is blocked until resolved)" >&2
  grep -qx "$p" "$locks/SMOKE_FAIL" 2>/dev/null || echo "$p" >> "$locks/SMOKE_FAIL"
}

# --- AUR package: one fresh container (D1) ----------------------------------
build_aur() {
  local p="$1" base built=0 attempt
  # clone the PackageBase, not the pkgname (review m8: identical for all 32
  # today; a split-package entry would clone an empty repo)
  base=$(jq -r --arg n "$p" '.results[] | select(.Name==$n) | .PackageBase' /tmp/aur-rpc.json)
  [[ -n "$base" && "$base" != "null" ]] || base="$p"
  for attempt in 1 2; do
    msg "=== building $p (fresh container, attempt $attempt) ==="
    # podman does not auto-create bind-mount sources (docker does); leftovers
    # hold subuid-owned files (rootless builder user), so remove them inside
    # the user namespace
    podman unshare rm -rf "/tmp/aur-build-$p"; mkdir -p "/tmp/aur-build-$p"
    # the full container output also lands in a per-package log (D1: every
    # failure attributable to one package, with its own transcript)
    if podman run --rm --pids-limit=-1 -v astroos-pacman-cache:/var/cache/pacman/pkg -v "$out":/repo -v /tmp/aur-build-$p:/work -v "$here/aur-patches":/patches:ro "$IMG" bash -c '
      set -euo pipefail
      p='"$p"'
      base='"$base"'
      # local repo of already-built packages (SigLevel Never: build-time only,
      # the published repo is signature-verified by clients)
      pkgs=$(find /repo -maxdepth 1 -name "*.pkg.tar*" ! -name "*.sig" | sort)
      if [ -n "$pkgs" ]; then
        # regenerate EVERY container, from scratch: a db inherited from
        # container N-1 lacks N-1 own output (run 4: psfex could not resolve
        # sextractor), and a db that is only ever appended to keeps entries
        # for packages purged since. A broken db is a hard failure (review m9).
        rm -f /repo/astroos-local.*
        repo-add -q /repo/astroos-local.db.tar.gz $pkgs >/dev/null 2>&1
        printf "[astroos-local]\nSigLevel = Never\nServer = file:///repo\n" >> /etc/pacman.conf
      fi
      pacman -Syu --noconfirm --needed git base-devel >/dev/null
      useradd -m builder
      echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
      cd /work
      git clone --quiet "https://aur.archlinux.org/$base.git" pkg
      # capture the commit BEFORE chown: root git on a builder-owned repo
      # trips safe.directory ("dubious ownership")
      git -C pkg rev-parse HEAD > /work/COMMIT
      # provenance material for aur-map.lock (D5): raw .SRCINFO source+sums,
      # as published by the AUR, i.e. BEFORE any aur-patches edit
      awk -F" = " "/^\t(source|sha256sums|sha512sums|b2sums)/ {print \$0}" pkg/.SRCINFO > /work/SRCINFO_SOURCES || true
      # aur-patches mechanism (council R3 D6): tracked scripts adjust a stale
      # PKGBUILD in place; applied patches are recorded in aur-map.lock
      touch /work/PATCHES
      if [[ -d /patches/$p ]]; then
        for f in /patches/$p/*.sh; do
          [[ -e "$f" ]] || continue
          (cd pkg && bash "$f")
          basename "$f" >> /work/PATCHES
        done
      fi
      chown -R builder:builder pkg
      cd pkg
      export MAKEFLAGS="-j$(nproc)"
      # Arch makepkg.conf now defaults OPTIONS to include "debug": every
      # compiled package would also emit <pkg>-debug, which then lands in the
      # repo db and trips the exact-scope check (D4). Build without.
      # (appended as a bash array extension: makepkg sources this file, and
      # its option lookup scans from the END, so the last word wins)
      echo "OPTIONS+=(!debug)" >> /etc/makepkg.conf
      grep -q "OPTIONS+=(!debug)" /etc/makepkg.conf
      su builder -c "makepkg --noconfirm -s"
      # Copy ONLY the package named $p. Split siblings (python-parfive-doc)
      # and any -debug output must never reach the repo: scope is an exact
      # set, and the ISO build hard-fails on extra names (D4).
      # (any PKGEXT: geant4 overrides it, so never assume .pkg.tar.zst)
      own=""
      for f in ./*.pkg.tar*; do
        [[ -e "$f" && "$f" != *.sig ]] || continue
        n=$(basename "$f"); n=${n%%.pkg.tar*}; n=${n%-*}; n=${n%-*}; n=${n%-*}
        [[ "$n" == "$p" ]] && own="$f"
      done
      [[ -n "$own" ]] || { echo "!! no package file named $p among: $(ls ./*.pkg.tar* 2>/dev/null)" >&2; exit 1; }
      cp "$own" /repo/
      # pkgver-pkgrel AS BUILT (review M5): exact for VCS packages
      n=$(basename "$own"); n=${n%%.pkg.tar*}; n=${n%-*}; echo "${n#"$p-"}" > /work/PKGVER
      # upstream VCS checkouts makepkg made (git+ sources): record their commits
      : > /work/VCS_COMMITS
      for d in src/*/; do
        [[ -d "$d/.git" ]] || continue
        echo "$(basename "$d") $(git -c safe.directory="*" -C "$d" rev-parse HEAD)" >> /work/VCS_COMMITS
      done
    ' 2>&1 | tee "$locks/$p.build.log"; then
      built=1; break
    fi
    # A source mirror reset (gnuastro via ftpmirror.gnu.org, 2026-09-05) is
    # not a recipe failure: one retry, then attribute.
    if (( attempt == 1 )) && grep -q "Failure while downloading" "$locks/$p.build.log"; then
      msg "$p: source download failed at the mirror; retrying once in 30s"
      sleep 30; continue
    fi
    break
  done
  if (( ! built )); then
    # Hermetic container: the failure is attributable to $p alone (its
    # transcript: locks/$p.build.log). Record it and keep going so one
    # stale package cannot stall the rest of the scope; the run still ends
    # non-zero and nothing is signed (below).
    echo "!! build failed: $p (recorded; continuing with the rest of the scope)" >&2
    echo "$p" >> "$locks/BUILD_FAIL"
    podman unshare rm -rf "/tmp/aur-build-$p"
    return 0
  fi
  jq -n --arg name "$p" \
        --arg base "$base" \
        --arg commit "$(cat /tmp/aur-build-$p/COMMIT)" \
        --arg pkgver "$(cat /tmp/aur-build-$p/PKGVER)" \
        --arg epoch "$(date +%s)" \
        --rawfile src /tmp/aur-build-$p/SRCINFO_SOURCES \
        --rawfile pat /tmp/aur-build-$p/PATCHES \
        --rawfile vcs /tmp/aur-build-$p/VCS_COMMITS \
        '{name:$name, source:"aur", aur_package_base:$base, aur_commit:$commit, pkgver:$pkgver, build_epoch:($epoch|tonumber),
          vcs_commits:($vcs|split("\n")|map(select(length>0))),
          srcinfo_sources_prepatch:($src|split("\n")|map(select(length>0))),
          patches:($pat|split("\n")|map(select(length>0)))}' > "$locks/$p.json"
  podman unshare rm -rf /tmp/aur-build-$p
  smoke_check "$p"
}

# --- local package: version + identity from git, one fresh container -------
local_inputs() {
  local d="$here/pkgs/$1" l
  echo "$d"
  [[ -f "$d/inputs" ]] || return 0
  while read -r l; do
    l="${l%%#*}"; l="${l%"${l##*[![:space:]]}"}"
    [[ -n "$l" ]] && echo "$repo/$l"
  done < "$d/inputs"
}
# identity of the inputs: the last commit touching them, or "dirty-<epoch>"
local_inputs_id() {
  local -a in; mapfile -t in < <(local_inputs "$1")
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && [[ -z "$(git -C "$repo" status --porcelain -- "${in[@]}")" ]]; then
    git -C "$repo" log -1 --format=%H -- "${in[@]}"
  else
    echo "dirty-$(date +%s)"
  fi
}
local_version() {
  local -a in; mapfile -t in < <(local_inputs "$1")
  local ts=""
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && [[ -z "$(git -C "$repo" status --porcelain -- "${in[@]}")" ]]; then
    ts=$(git -C "$repo" log -1 --format=%ct -- "${in[@]}")
  fi
  [[ -n "$ts" ]] || ts=$(date +%s)
  date -u -d "@$ts" +%Y%m%d.%H%M
}

build_local() {
  local p="$1" id ver old
  id=$(local_inputs_id "$p"); ver=$(local_version "$p")
  if [[ -s "$locks/$p.json" ]] && own_pkg_file "$p" >/dev/null \
     && [[ "$(jq -r .inputs_id "$locks/$p.json")" == "$id" ]]; then
    msg "=== $p already built from $id, skipping ==="
    return 0
  fi
  # one artifact per name in the db: a rebuild replaces the previous file
  old=$(own_pkg_file "$p" || true)
  [[ -n "$old" ]] && rm -f "$old" "$old.sig"
  msg "=== building local package $p (VERSION $ver, inputs $id; fresh container) ==="
  podman unshare rm -rf "/tmp/aur-build-$p"; mkdir -p "/tmp/aur-build-$p/pkg"
  cp -r "$here/pkgs/$p/." "/tmp/aur-build-$p/pkg/"
  cp -r "$here/branding/out" "/tmp/aur-build-$p/pkg/assets"
  cp -r "$here/meta" "/tmp/aur-build-$p/pkg/meta"
  echo "$ver" > "/tmp/aur-build-$p/pkg/VERSION"
  if podman run --rm --pids-limit=-1 -v astroos-pacman-cache:/var/cache/pacman/pkg -v "$out":/repo -v /tmp/aur-build-$p:/work "$IMG" bash -c '
      set -euo pipefail
      p='"$p"'
      pkgs=$(find /repo -maxdepth 1 -name "*.pkg.tar*" ! -name "*.sig" | sort)
      if [ -n "$pkgs" ]; then
        rm -f /repo/astroos-local.*
        repo-add -q /repo/astroos-local.db.tar.gz $pkgs >/dev/null 2>&1
        printf "[astroos-local]\nSigLevel = Never\nServer = file:///repo\n" >> /etc/pacman.conf
      fi
      pacman -Syu --noconfirm --needed git base-devel >/dev/null
      useradd -m builder
      echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
      chown -R builder:builder /work/pkg
      cd /work/pkg
      export MAKEFLAGS="-j$(nproc)"
      echo "OPTIONS+=(!debug)" >> /etc/makepkg.conf
      su builder -c "makepkg --noconfirm -s"
      own=""
      for f in ./*.pkg.tar*; do
        [[ -e "$f" && "$f" != *.sig ]] || continue
        n=$(basename "$f"); n=${n%%.pkg.tar*}; n=${n%-*}; n=${n%-*}; n=${n%-*}
        [[ "$n" == "$p" ]] && own="$f"
      done
      [[ -n "$own" ]] || { echo "!! no package file named $p among: $(ls ./*.pkg.tar* 2>/dev/null)" >&2; exit 1; }
      cp "$own" /repo/
      n=$(basename "$own"); n=${n%%.pkg.tar*}; n=${n%-*}; echo "${n#"$p-"}" > /work/PKGVER
    ' 2>&1 | tee "$locks/$p.build.log"; then
    jq -n --arg name "$p" --arg id "$id" --arg pkgver "$(cat /tmp/aur-build-$p/PKGVER)" --arg epoch "$(date +%s)" \
      '{name:$name, source:"local", inputs_id:$id, pkgver:$pkgver, build_epoch:($epoch|tonumber)}' > "$locks/$p.json"
  else
    echo "!! build failed: $p (recorded; continuing)" >&2
    echo "$p" >> "$locks/BUILD_FAIL"
  fi
  podman unshare rm -rf "/tmp/aur-build-$p"
}

# --- build: every package, then sign -----------------------------------------
do_build() {
  scope_preflight
  mkdir -p "$out" "$locks"
  [[ -f "$keys/FINGERPRINT" ]] || die "no signing key — run: $0 keygen"
  local order; order=$(topo_order "${PKGS[@]}")
  msg "build order: $order ${LOCALS[*]:-}"
  rm -f "$locks/BUILD_FAIL"
  local -a ALL=("${PKGS[@]}" "${LOCALS[@]}")

  # Purge anything in out/ whose pkgname is not in scope: -debug and split
  # -doc siblings copied by earlier runs, or packages excluded since. The
  # repo db is built from out/*.pkg.tar*, and the ISO build asserts db
  # names == scope exactly (D4), so out/ must equal the scope.
  local f n
  while read -r f; do
    n=$(pkgname_of "$f")
    printf '%s\n' "${ALL[@]}" | grep -qx "$n" && continue
    msg "purging out-of-scope artifact: $(basename "$f")"
    rm -f "$f" "$f.sig" "$locks/$n.json"
  done < <(pkg_files)
  for f in "$locks"/*.json; do
    [[ -e "$f" ]] || continue
    n=$(basename "$f" .json)
    printf '%s\n' "${ALL[@]}" | grep -qx "$n" || { msg "purging out-of-scope lock: $n"; rm -f "$f"; }
  done

  local p
  for p in $order; do
    # resumability: a finished package (its OWN artifact + lock entry) is not
    # rebuilt; its import smoke still reruns (seconds) so a resumed run
    # carries a complete D6 verdict.
    if [[ -s "$locks/$p.json" ]] && own_pkg_file "$p" >/dev/null; then
      msg "=== $p already built, skipping ==="
      smoke_check "$p"
      continue
    fi
    build_aur "$p"
  done
  for p in "${LOCALS[@]}"; do build_local "$p"; done

  # D6 verdict: every failure recorded above blocks signing. Resolution per
  # R3 D6 is exclusion, not a silent ship: drop the name from meta/aur.list
  # (documented pip/uv fallback), delete its package + lock, lower
  # ASTROOS_AUR_SCOPE, rerun — banked packages are skipped, so that is fast.
  if [[ -s "$locks/BUILD_FAIL" ]]; then
    die "build FAILED for: $(tr '\n' ' ' < "$locks/BUILD_FAIL"); patch via aur-patches/<pkg>/ (R3 D6) or exclude, then rerun (banked packages are skipped)"
  fi
  if [[ -s "$locks/SMOKE_FAIL" ]]; then
    die "import smoke FAILED (D6 gate) for: $(tr '\n' ' ' < "$locks/SMOKE_FAIL"); exclude per R3 D6 and rerun"
  fi

  # sign packages + build the real db (signed), assemble aur-map.lock (D5)
  msg "=== signing + repo db ==="
  rm -f "$out"/astroos-local.* "$out"/astroos.db* "$out"/astroos.files* 2>/dev/null || true
  podman run --rm -v "$out":/repo -v "$keys":/keys "$IMG" bash -c '
    set -euo pipefail
    export GNUPGHOME=/keys
    fpr=$(cat /keys/FINGERPRINT)
    cd /repo
    pkgs=$(find . -maxdepth 1 -name "*.pkg.tar*" ! -name "*.sig" | sort)
    for f in $pkgs; do gpg --batch --yes --pinentry-mode loopback --passphrase "" --detach-sign -u "$fpr" "$f"; done
    repo-add --sign --key "$fpr" astroos.db.tar.zst $pkgs
    # repo-add leaves astroos.db/.files (+.sig) as SYMLINKS to the tarballs.
    # Blob storage serves real files, so replace the links with copies. The
    # links must go first: cp onto a symlink of its own source is refused as
    # "same file" and would abort this container.
    rm -f astroos.db astroos.db.sig astroos.files astroos.files.sig
    cp astroos.db.tar.zst astroos.db; cp astroos.db.tar.zst.sig astroos.db.sig
    cp astroos.files.tar.zst astroos.files; cp astroos.files.tar.zst.sig astroos.files.sig
    ls -l astroos.db astroos.db.sig astroos.files astroos.files.sig'
  jq -s --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{published:$date, packages:.}' "$locks"/*.json > "$out/aur-map.lock"
  sha256sum "$out/aur-map.lock" | awk '{print $1}' > "$out/aur-map.lock.sha256"
  podman run --rm -v "$out":/repo -v "$keys":/keys "$IMG" bash -c \
    'export GNUPGHOME=/keys; gpg --batch --yes --pinentry-mode loopback --passphrase "" --detach-sign -u "$(cat /keys/FINGERPRINT)" /repo/aur-map.lock'
  msg "build complete: $(pkg_files | wc -l) packages in $out ($(echo "$order" | wc -w) AUR + ${#LOCALS[@]} local)"
}

# --- local <name>: build one local package on its own (iteration/test) -------
do_local_one() {
  [[ -n "$arg" && -f "$here/pkgs/$arg/PKGBUILD" ]] || die "usage: $0 local <name>  (one of: $(local_names | tr '\n' ' '))"
  mkdir -p "$out" "$locks"
  rm -f "$locks/BUILD_FAIL"
  build_local "$arg"
  [[ -s "$locks/BUILD_FAIL" ]] && die "local build FAILED: $arg (see $locks/$arg.build.log)"
  msg "built: $(own_pkg_file "$arg")"
}

# --- publish: packages first, db + lock LAST (risk #2) ---------------------
do_publish() {
  [[ -s "$sas_file" ]] || die "no SAS token at $sas_file (generate on the laptop, scp here)"
  command -v azcopy >/dev/null || die "azcopy not installed"
  # never ship a repo whose build stage is on record as failed (review B1)
  [[ -s "$locks/BUILD_FAIL" ]] && die "publish refused: build failures on record: $(tr '\n' ' ' < "$locks/BUILD_FAIL")"
  [[ -s "$locks/SMOKE_FAIL" ]] && die "publish refused: import-smoke failures on record: $(tr '\n' ' ' < "$locks/SMOKE_FAIL")"
  [[ -s "$out/astroos.db.tar.zst" && -s "$out/astroos.db.tar.zst.sig" && -s "$out/aur-map.lock.sig" ]] \
    || die "publish refused: no signed db in $out (run build first)"
  local sas; sas=$(tr -d '\r\n' < "$sas_file")
  local base="https://${account}.blob.core.windows.net/${container}/astroos/x86_64"
  msg "publish stage 1: packages + signatures"
  azcopy copy "$out/*.pkg.tar*" "${base}?${sas}" >/dev/null   # packages + their .sig, any PKGEXT
  # Stage 2: each signature BEFORE its file, so a client syncing mid-upload
  # sees old-db + new-sig (invalid, retried on the next -Sy) rather than
  # new-db + old-sig; blob storage has no multi-object atomicity, the window
  # is seconds long and recorded in the ledger (review m7).
  msg "publish stage 2: db + lock (signatures first)"
  for f in astroos.files.tar.zst.sig astroos.files.tar.zst astroos.files.sig astroos.files \
           aur-map.lock.sig aur-map.lock.sha256 aur-map.lock \
           astroos.db.tar.zst.sig astroos.db.tar.zst astroos.db.sig astroos.db; do
    azcopy copy "$out/$f" "${base}/$f?${sas}" >/dev/null
  done
  # promotion manifest -> synced into git at the next laptop session (D5)
  {
    echo "published=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "repo_db_sha256=$(sha256sum "$out/astroos.db.tar.zst" | awk '{print $1}')"
    echo "lock_sha256=$(cat "$out/aur-map.lock.sha256")"
    echo "package_count=$(pkg_files | wc -l)"
    echo "base_url=$base"
  } > "$out/PROMOTION"
  msg "published to $base — PROMOTION manifest written"
}

case "$cmd" in
  keygen)    do_keygen ;;
  preflight) scope_preflight ;;   # scope + AUR liveness + migration only (CI, R3 D7 standing check)
  build)     do_build ;;
  local)     do_local_one ;;
  publish)   do_publish ;;
  all)       do_build; do_publish ;;
  *) die "usage: $0 [keygen|preflight|build|local <name>|publish|all]" ;;
esac
