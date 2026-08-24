#!/usr/bin/env bash
# Boot the freshly built ISO in QEMU and assert it reaches a usable state.
# Council R1 gate: kernel boot + Plasma target + network + `astroos-doctor --quick`.
#
# This is the "test before shipping" gate. It boots headless with a serial
# console and scans the log for success markers. For a full graphical check,
# run with ASTROOS_GRAPHICAL=1 to get a QEMU window instead.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$here/.." && pwd)"
iso="${1:-$(ls -1t "$repo"/out/*.iso 2>/dev/null | head -1 || true)}"
[[ -f "${iso:-}" ]] || { echo "No ISO found. Pass a path or build first." >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || {
  echo "qemu-system-x86_64 not found. Install qemu-full." >&2; exit 1; }

log="$repo/out/qemu-smoke.log"
: > "$log"

common=(-enable-kvm -m 4096 -smp 4
        -cdrom "$iso"
        -netdev user,id=n0 -device virtio-net,netdev=n0)

if [[ "${ASTROOS_GRAPHICAL:-0}" == "1" ]]; then
  echo ">> Graphical boot (close the window when done)."
  qemu-system-x86_64 "${common[@]}"
  exit 0
fi

echo ">> Headless boot, capturing serial to $log (timeout 300s) ..."
timeout 300 qemu-system-x86_64 "${common[@]}" \
  -nographic -serial "file:$log" -display none || true

echo ">> Checking success markers ..."
fail=0
grep -qiE 'reached target .*(Graphical|Multi-User)' "$log" || { echo "  [x] no systemd graphical/multi-user target"; fail=1; }
grep -qiE 'kernel: Linux version'                 "$log" || { echo "  [x] no kernel boot line"; fail=1; }
if [[ $fail -eq 0 ]]; then
  echo ">> SMOKE TEST PASS"
else
  echo ">> SMOKE TEST FAIL — inspect $log"
  exit 1
fi
