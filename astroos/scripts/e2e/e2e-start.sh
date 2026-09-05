#!/usr/bin/env bash
# Start the AstroOS end-to-end install guest: fresh UEFI machine, blank 40 GB
# virtio disk, the release ISO as the boot medium, QMP control socket for
# mouse/keyboard/screenshots (driven by e2e.py). With "disk" as the first
# argument the guest boots the installed disk instead (no ISO attached).
#
#   e2e-start.sh [iso [path/to.iso] | disk]
#
# E2E_DIR (default /tmp/e2e) holds the disk image, OVMF vars, QMP socket and
# logs. Delete $E2E_DIR/disk.qcow2 for a clean machine. Host needs qemu with
# KVM and the OVMF 4M firmware (Ubuntu: qemu-system-x86 ovmf).
set -euo pipefail
d="${E2E_DIR:-/tmp/e2e}"
mkdir -p "$d"
mode="${1:-iso}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # astroos/ dir
repo="$(cd "$here/.." && pwd)"
iso="${2:-$(ls -1t "$repo"/out/astroos-desktop-linux-*.iso 2>/dev/null | head -1 || true)}"

if [[ -f $d/qemu.pid ]] && kill -0 "$(cat "$d/qemu.pid")" 2>/dev/null; then
  echo "guest already running (pid $(cat "$d/qemu.pid")); stop it first (e2e.py quit)" >&2
  exit 1
fi
[[ -e /dev/kvm ]] || { echo "no /dev/kvm on this host" >&2; exit 1; }
ovmf=/usr/share/OVMF
[[ -f $ovmf/OVMF_CODE_4M.fd ]] || { echo "OVMF_CODE_4M.fd not found under $ovmf (install ovmf)" >&2; exit 1; }
[[ -f $d/disk.qcow2 ]] || qemu-img create -f qcow2 "$d/disk.qcow2" "${E2E_DISK_SIZE:-40G}" >/dev/null
[[ -f $d/OVMF_VARS.fd ]] || cp "$ovmf/OVMF_VARS_4M.fd" "$d/OVMF_VARS.fd"
rm -f "$d/qmp.sock"

# shellcheck disable=SC2054  # the commas are inside single qemu arguments
args=(
  -enable-kvm -cpu host -m "${E2E_MEM_MIB:-8192}" -smp "${E2E_SMP:-6}"
  -drive if=pflash,format=raw,readonly=on,file="$ovmf/OVMF_CODE_4M.fd"
  -drive if=pflash,format=raw,file="$d/OVMF_VARS.fd"
  -drive file="$d/disk.qcow2",if=none,id=hd,format=qcow2
  -device virtio-blk-pci,drive=hd,bootindex=1
  -netdev user,id=n0 -device virtio-net,netdev=n0
  -device virtio-vga -display none
  -device qemu-xhci -device usb-tablet -device usb-kbd
  -qmp unix:"$d/qmp.sock",server,nowait
  -serial file:"$d/serial-$mode.log"
)
if [[ $mode == iso ]]; then
  [[ -f ${iso:-} ]] || { echo "no ISO (pass a path or build first)" >&2; exit 1; }
  # shellcheck disable=SC2054
  args+=(-drive file="$iso",if=none,id=cd,media=cdrom,readonly=on -device ide-cd,drive=cd,bootindex=0)
  echo "booting $iso"
fi

nohup qemu-system-x86_64 "${args[@]}" > "$d/qemu-$mode.log" 2>&1 < /dev/null &
echo $! > "$d/qemu.pid"
sleep 2
kill -0 "$(cat "$d/qemu.pid")" 2>/dev/null || { echo "qemu exited:"; cat "$d/qemu-$mode.log"; exit 1; }
echo "guest started ($mode), pid $(cat "$d/qemu.pid"), control: E2E_DIR=$d python3 $(dirname "${BASH_SOURCE[0]}")/e2e.py shot $d/s.png"
