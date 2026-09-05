#!/usr/bin/env bash
# Boot the freshly built ISO in QEMU and assert the Phase 0.5 gate:
#   kernel boot + multi-user + graphical (sddm/Plasma) target
#   + network-online + astroos-doctor --quick (via astroos-smoke.service).
#
# The shipped ISO boots with no serial console on its cmdline, so grepping a
# serial log through the ISO's own bootloader can never see boot markers.
# Instead we direct-kernel-boot (-kernel/-initrd extracted from the ISO) and
# append console=ttyS0 plus the astroos.smoke flag that arms the in-image
# astroos-smoke.service (inert on normal boots). The ISO itself is untouched.
# ASTROOS_GRAPHICAL=1 opens a QEMU window using the ISO's own bootloader.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$here/.." && pwd)"
iso="${1:-$(ls -1t "$repo"/out/*.iso 2>/dev/null | head -1 || true)}"
[[ -f "${iso:-}" ]] || { echo "No ISO found. Pass a path or build first." >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || {
  echo "qemu-system-x86_64 not found. Install qemu." >&2; exit 1; }
command -v bsdtar >/dev/null 2>&1 || {
  echo "bsdtar not found. Install libarchive." >&2; exit 1; }

accel=(); timeout=600
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  accel=(-enable-kvm -cpu host)
else
  # linux-cachyos needs x86-64-v3: TCG must emulate a v3-capable CPU (-cpu max).
  echo ">> /dev/kvm unavailable — TCG fallback (slow, extended timeout)."
  accel=(-cpu max)
  timeout=2400
fi

# shellcheck disable=SC2054  # the commas are inside single qemu arguments
common=("${accel[@]}" -m 4096 -smp 4 -cdrom "$iso"
        -netdev user,id=n0 -device virtio-net,netdev=n0)

if [[ "${ASTROOS_GRAPHICAL:-0}" == "1" ]]; then
  echo ">> Graphical boot (close the window when done)."
  qemu-system-x86_64 "${common[@]}"
  exit 0
fi

# ISO 9660 volume label from the primary volume descriptor (offset 0x8028).
label="$(dd if="$iso" bs=1 skip=32808 count=32 2>/dev/null | tr -d ' \0')"
[[ -n "$label" ]] || { echo "Could not read ISO volume label." >&2; exit 1; }

# Extract the stock-linux kernel and its matching initramfs (+ ucode).
# (chmod first: bsdtar restores read-only modes that make rm noisy.)
x="$(mktemp -d)"; trap 'chmod -R u+w "$x" 2>/dev/null; rm -rf "$x"' EXIT
bsdtar -C "$x" -xf "$iso" 'arch/boot/*' 2>/dev/null || true
kernel="$(ls "$x"/arch/boot/x86_64/vmlinuz-* 2>/dev/null | sort | head -1)"
[[ -n "${kernel:-}" ]] || { echo "No kernel found in ISO." >&2; exit 1; }
kname="${kernel##*/vmlinuz-}"
initramfs="$x/arch/boot/x86_64/initramfs-$kname.img"
[[ -f "$initramfs" ]] || { echo "No initramfs for $kname in ISO." >&2; exit 1; }
initrd="$x/smoke-initrd.img"
cat "$x"/arch/boot/*ucode.img "$initramfs" 2>/dev/null > "$initrd" \
  || cat "$initramfs" > "$initrd"

mkdir -p "$repo/out" 2>/dev/null || true
log="$repo/out/qemu-smoke.log"
: > "$log" 2>/dev/null || { log="$(mktemp /tmp/qemu-smoke.XXXX.log)"; echo ">> out/ not writable; logging to $log"; }
echo ">> Headless boot: label=$label kernel=vmlinuz-$kname timeout=${timeout}s"
qemu-system-x86_64 "${common[@]}" \
  -kernel "$kernel" -initrd "$initrd" \
  -append "archisobasedir=arch archisolabel=$label console=ttyS0,115200 astroos.smoke" \
  -display none -serial "file:$log" &
qpid=$!

# Early exit once the doctor verdict lands (or qemu dies), else hard timeout.
waited=0
while kill -0 "$qpid" 2>/dev/null && (( waited < timeout )); do
  grep -qE 'ASTROOS-SMOKE-DOCTOR-(PASS|FAIL)' "$log" && break
  sleep 5; waited=$((waited+5))
done
sleep 3  # let trailing serial output flush
kill "$qpid" 2>/dev/null || true
wait "$qpid" 2>/dev/null || true

echo ">> Checking gate markers ..."
# In-guest verdicts from astroos-smoke-report (serial-log scraping of systemd
# messages is unreliable: early lines drop, plymouth eats target messages).
fail=0
check() { grep -qiE "$1" "$log" && echo "  [ok] $2" || { echo "  [x] $2"; fail=1; }; }
check 'running hook \[archiso\]'    'kernel + archiso initramfs'
check ' login:'                     'multi-user (serial getty up)'
check 'ASTROOS-SMOKE-GRAPHICAL-OK'  'graphical target (plasmalogin)'
check 'ASTROOS-SMOKE-NET-OK'        'network online'
check 'ASTROOS-SMOKE-DOCTOR-PASS'   'astroos-doctor --quick'
if [[ $fail -eq 0 ]]; then
  echo ">> SMOKE TEST PASS"
else
  echo ">> SMOKE TEST FAIL — inspect $log"
  exit 1
fi
