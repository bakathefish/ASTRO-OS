#!/usr/bin/env bash
# AstroOS forge driver: run the release pipeline on the Azure build VM from
# the laptop with nothing to babysit.
#
#   start VM -> sync HEAD (git bundle) -> run forge.sh there -> stream the
#   stage lines here -> collect artifacts + manifests -> record the release
#   in git (council R3 D5: promotion manifests live in the tree) -> deallocate.
#
#   forge-remote.sh [--keep-vm] [--no-sync] [--no-commit] [stage ...]
#     stages default to forge.sh's full order: repo publish verify iso gate audit release
#     --keep-vm    leave the VM running afterwards (default: deallocate)
#     --no-sync    do not push laptop HEAD to the VM first
#     --no-commit  do not commit the release record into astroos/releases/
#
# A release record is written only when forge.sh exits 0, the run included the
# matching stage, and out/RELEASE carries this run's run_start; the VM is
# deallocated on every exit path unless --keep-vm.
#
# Needs on the laptop: az (logged in), git, ssh + scp with a key for the VM
# user. Runs from git-bash on Windows or any POSIX shell. Every step is safe
# to rerun; forge.sh itself resumes at the failed stage.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"    # astroos/
repo="$(cd "$here/.." && pwd)"
RG="${ASTROOS_RG:-astroos-build-rg}"
VM="${ASTROOS_VM:-astroos-forge}"
HOST="${ASTROOS_VM_HOST:-astro@20.114.167.180}"
RDIR="${ASTROOS_VM_REPO:-/home/astro/ASTRO-OS}"

keep=0; sync=1; commit=1; stages=()
# shellcheck disable=SC2034  # keep is read inside the EXIT trap string below
for a in "$@"; do
  case "$a" in
    --keep-vm) keep=1 ;; --no-sync) sync=0 ;; --no-commit) commit=0 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) stages+=("$a") ;;
  esac
done

msg() { echo ">> $*"; }
die() { echo "!! $*" >&2; exit 1; }
ssh_() { ssh -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new "$HOST" "$@"; }
# the stage list as forge.sh sees it: empty means its full default order
has_stage() {
  local s
  (( ${#stages[@]} )) || return 0
  for s in "${stages[@]}"; do [[ "$s" == "$1" ]] && return 0; done
  return 1
}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# --- 1. laptop preconditions: everything that can refuse, before we pay -----
if (( sync )); then
  [[ -z "$(git -C "$repo" status --porcelain)" ]] || die "laptop tree is dirty; commit first (the VM builds HEAD)"
  branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  [[ "$branch" != HEAD ]] || die "detached HEAD; check out a branch (the VM fetches it by name)"
  local_head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" bundle create "$tmp/astroos.bundle" "$branch" >/dev/null 2>&1 \
    || die "git bundle create failed for branch $branch"
fi

# --- 2. VM up --------------------------------------------------------------
state=$(az vm get-instance-view -g "$RG" -n "$VM" --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv | tr -d '\r')
msg "VM $VM: ${state:-unknown}"
if [[ "$state" != "VM running" ]]; then
  msg "starting $VM"
  az vm start -g "$RG" -n "$VM" -o none
fi
# from here the VM bills by the minute: give it back on every exit path
# shellcheck disable=SC2154  # rc is assigned inside the trap string
trap 'rc=$?; if (( keep )); then msg "VM left running (--keep-vm): remember az vm deallocate -g $RG -n $VM"; else msg "deallocating $VM"; az vm deallocate -g "$RG" -n "$VM" -o none || true; fi; rm -rf "$tmp"; exit $rc' EXIT
for _ in $(seq 1 30); do ssh_ true 2>/dev/null && break; sleep 10; done
ssh_ true 2>/dev/null || die "ssh to $HOST not reachable"

# --- 3. sync laptop HEAD to the VM ----------------------------------------
if (( sync )); then
  scp -q "$tmp/astroos.bundle" "$HOST:/home/astro/astroos.bundle"
  vm_head=$(ssh_ "cd $RDIR && git fetch -q /home/astro/astroos.bundle $branch && git reset -q --hard FETCH_HEAD && git rev-parse HEAD" | tr -d '\r')
  [[ "$vm_head" == "$local_head" ]] || die "VM HEAD $vm_head != laptop HEAD $local_head after sync"
  msg "VM at $(git -C "$repo" log --oneline -1) ($branch)"
fi

# --- 4. launch forge.sh detached ------------------------------------------
stage_str="${stages[*]:-}"
msg "launching forge.sh ${stage_str:-(all stages)}"
ssh_ "cd $RDIR && mkdir -p out && rm -f out/forge.exit && (nohup bash -c 'bash astroos/scripts/forge.sh $stage_str; echo \$? > out/forge.exit' >> out/forge.stdout 2>&1 < /dev/null &)"

# --- 5. stream stage lines until it exits ---------------------------------
last=0; code=""
while :; do
  out=$(ssh_ "grep -nE '^\[[^]]*\] (## STAGE|verify:|iso:|gate:|audit:|release:|forge |!! )|^>> === |^!! ' $RDIR/out/forge.log 2>/dev/null; echo ---SEP---; cat $RDIR/out/forge.exit 2>/dev/null" 2>/dev/null | tr -d '\r') \
    || { sleep 30; continue; }
  new=$(printf '%s\n' "$out" | awk '/^---SEP---$/{exit} {print}' | awk -F: -v l="$last" '($1+0)>l')
  if [[ -n "$new" ]]; then
    printf '%s\n' "$new" | cut -d: -f2- | cut -c1-200
    last=$(printf '%s\n' "$new" | tail -1 | cut -d: -f1)
  fi
  code=$(printf '%s\n' "$out" | awk 'f{print} /^---SEP---$/{f=1}' | head -1)
  [[ -n "$code" ]] && break
  sleep 60
done
msg "forge.sh exited $code"

# --- 6. collect artifacts + manifests --------------------------------------
dst="$repo/out/forge-$(date +%Y%m%d-%H%M)"; mkdir -p "$dst"
for f in forge.log forge.status forge.stdout audit.txt RELEASE RUN_START build-metadata.txt sha256sums.txt manifest.pkglist qemu-smoke.log aurrepo.log; do
  scp -q "$HOST:$RDIR/out/$f" "$dst/" 2>/dev/null || true
done
for f in PROMOTION aur-map.lock aur-map.lock.sha256; do
  scp -q "$HOST:$RDIR/out/astroos-repo/x86_64/$f" "$dst/" 2>/dev/null || true
done
msg "artifacts: $dst"
[[ -f "$dst/RELEASE" ]] && { echo "--- RELEASE"; cat "$dst/RELEASE"; }
[[ -f "$dst/forge.status" ]] && { echo "--- stages"; cat "$dst/forge.status"; }

# --- 7. release record into the tree (R3 D5) --------------------------------
# Only a run that succeeded, ran the stage, and left artifacts of THIS run gets
# recorded: forge.sh stamps out/RUN_START and repeats it as run_start= in
# RELEASE, so a RELEASE left over from an earlier build never becomes today's.
fresh_release() {
  local ran stamped
  [[ -f "$dst/RUN_START" && -f "$dst/RELEASE" ]] || return 1
  ran=$(tr -d ' \t\r\n' < "$dst/RUN_START")
  stamped=$(grep -E '^run_start=' "$dst/RELEASE" | head -1 | cut -d= -f2 | tr -d ' \t\r\n')
  [[ -n "$ran" && "$ran" == "$stamped" ]]
}

rel="$here/releases/$(date -u +%Y-%m-%d)"
record=""
if [[ "$code" != 0 ]]; then
  msg "no release record (forge exit $code)"
elif [[ -f "$dst/RELEASE" ]] && has_stage release && fresh_release; then
  record="release"
elif [[ -f "$dst/PROMOTION" ]] && has_stage publish; then
  record="repo-only"
  [[ -f "$dst/RELEASE" ]] && msg "RELEASE ignored (not from this run): recording the repo promotion only"
elif [[ -f "$dst/RELEASE" || -f "$dst/PROMOTION" ]]; then
  msg "no release record (collected manifests are not from this run)"
fi

if [[ -n "$record" ]]; then
  mkdir -p "$rel"
  files=(PROMOTION audit.txt build-metadata.txt forge.status aur-map.lock.sha256)
  [[ "$record" == release ]] && files=(RELEASE "${files[@]}")
  for f in "${files[@]}"; do
    [[ -f "$dst/$f" ]] && cp "$dst/$f" "$rel/$f"
  done
  if (( commit )); then
    desc="repo-only"
    [[ "$record" == release ]] && desc=$(grep -E '^iso=' "$rel/RELEASE" | head -1 | cut -d= -f2)
    git -C "$repo" add "$rel"
    git -C "$repo" commit -q -m "Release record $(date -u +%Y-%m-%d): ${desc:-repo-only} (forge exit $code)" \
      && msg "release record committed: $rel" || msg "nothing new to commit in $rel"
  else
    msg "release record staged (uncommitted): $rel"
  fi
fi

# --- 8. VM down: the EXIT trap deallocates unless --keep-vm -----------------
exit "$code"
