#!/usr/bin/env bash
# Run inside the LIVE guest (as liveuser, over ssh) after Calamares has
# finished and unmounted the target: mount the installed btrfs subvolumes,
# copy liveuser's authorized_keys to the new user's home and enable sshd, so
# the installed system can be verified over ssh after its first boot.
#   guest-postinstall-ssh.sh <user> [root-partition (/dev/vda2)]
set -euo pipefail
user="${1:?user}"
part="${2:-/dev/vda2}"
t=/mnt/e2e-target
sudo mkdir -p "$t"
sudo mount -o subvol=@ "$part" "$t"
sudo mount -o subvol=@home "$part" "$t/home"
uid=$(awk -F: -v u="$user" '$1==u {print $3}' "$t/etc/passwd")
gid=$(awk -F: -v u="$user" '$1==u {print $4}' "$t/etc/passwd")
[[ -n $uid && -n $gid ]] || { echo "user $user not in the target's passwd"; sudo umount -R "$t"; exit 1; }
sudo install -d -m700 -o "$uid" -g "$gid" "$t/home/$user/.ssh"
sudo install -m600 -o "$uid" -g "$gid" "$HOME/.ssh/authorized_keys" "$t/home/$user/.ssh/authorized_keys"
sudo mkdir -p "$t/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /usr/lib/systemd/system/sshd.service "$t/etc/systemd/system/multi-user.target.wants/sshd.service"
echo "== target identity"; sudo cat "$t/etc/os-release" | head -3; sudo cat "$t/etc/hostname"
echo "== target astroos packages"; sudo ls "$t/var/lib/pacman/local" | grep -E "^astroos-" || echo "(none)"
sudo umount -R "$t"
echo "sshd enabled and key installed for $user; power the guest off and boot the disk"
