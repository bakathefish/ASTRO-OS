#!/usr/bin/env bash
# Host-side alternative to guest-postinstall-ssh.sh: with the guest powered
# off, attach the installed disk image over qemu-nbd, mount the btrfs
# subvolumes, install the host user's public key for <user> and enable sshd.
# Use it when the live session cannot be reached any more after the install
# (2026-09-05: the live session's sshd died once the installer had filled the
# RAM-backed overlay with its package cache).
#   sudo host-inject-ssh.sh <user> [disk.qcow2 (E2E_DIR/disk.qcow2)] [pubkey (~/.ssh/id_ed25519.pub of SUDO_USER)]
set -euo pipefail
user="${1:?user}"
d="${E2E_DIR:-/tmp/e2e}"
img="${2:-$d/disk.qcow2}"
home_of="${SUDO_USER:-$USER}"
pub="${3:-$(getent passwd "$home_of" | cut -d: -f6)/.ssh/id_ed25519.pub}"
[[ -f $img ]] || { echo "no disk image at $img" >&2; exit 1; }
[[ -f $pub ]] || { echo "no public key at $pub" >&2; exit 1; }
if [[ -f $d/qemu.pid ]] && kill -0 "$(cat "$d/qemu.pid")" 2>/dev/null; then
  echo "guest still running (pid $(cat "$d/qemu.pid")); power it off first (e2e.py quit)" >&2; exit 1
fi
modprobe nbd max_part=8
nbd=/dev/nbd0
qemu-nbd -d "$nbd" >/dev/null 2>&1 || true
qemu-nbd -c "$nbd" "$img"
trap 'umount -R /mnt/e2e-target 2>/dev/null || true; qemu-nbd -d "$nbd" >/dev/null 2>&1 || true' EXIT
sleep 1; partprobe "$nbd" 2>/dev/null || true; sleep 1
root="${nbd}p2"
[[ -b $root ]] || { echo "no second partition on $nbd" >&2; lsblk "$nbd"; exit 1; }
t=/mnt/e2e-target
mkdir -p "$t"
mount -o subvol=@ "$root" "$t"
mount -o subvol=@home "$root" "$t/home"
uid=$(awk -F: -v u="$user" '$1==u {print $3}' "$t/etc/passwd")
gid=$(awk -F: -v u="$user" '$1==u {print $4}' "$t/etc/passwd")
[[ -n $uid && -n $gid ]] || { echo "user $user not in the target's passwd" >&2; exit 1; }
install -d -m700 -o "$uid" -g "$gid" "$t/home/$user/.ssh"
install -m600 -o "$uid" -g "$gid" "$pub" "$t/home/$user/.ssh/authorized_keys"
mkdir -p "$t/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/sshd.service "$t/etc/systemd/system/multi-user.target.wants/sshd.service"
echo "== target identity"; head -3 "$t/etc/os-release"; cat "$t/etc/hostname"
echo "== target astroos packages"
for p in "$t"/var/lib/pacman/local/astroos-*; do [[ -d $p ]] && basename "$p"; done
echo "== target package count: $(find "$t/var/lib/pacman/local" -mindepth 1 -maxdepth 1 -type d | wc -l)"
umount -R "$t"
echo "sshd enabled and key installed for $user; boot the disk (e2e-start.sh disk)"
