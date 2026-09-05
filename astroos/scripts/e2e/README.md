# End-to-end install test (QEMU, driven over QMP)

Calamares has no unattended mode, so the "install it and boot it" test drives
the real installer the way a user does: screenshots, mouse clicks and typed
text, sent to a headless KVM guest over QEMU's QMP socket. Nothing in the ISO
is changed for the test. Verification level 4 in `astroos/README.md`.

What it proves, in order:

1. the release ISO boots on UEFI firmware through its own GRUB menu into Plasma;
2. the installer binary links cleanly (`ldd /usr/bin/calamares`, the check
   that would have caught the 2026-09-05 boost 1.91/1.92 mismatch before release);
3. the AstroOS-branded installer completes an online install (all AstroOS
   groups plus BlackArch) onto a blank 40 GB disk;
4. the installed disk boots to the login screen on its own; and
5. `verify-installed.sh` passes inside the installed system: identity files,
   motd, hostname, terminal greetings, `[astroos]` and `[blackarch]` wiring and
   trust, the AstroOS packages and hooks, masks, services, the Zenbook Duo
   profile inert on non-Duo hardware, `astroos-doctor`.

Every guest boot has a new ssh host key on 127.0.0.1:2222, so use
`-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` for the guest
(the commands below abbreviate it to `ssh -p 2222 ...`). Run each install on a
fresh disk image: a second run over a failed one stopped at "failed to create
a partition table" (2026-09-05), and a clean machine is what a user has anyway.

Host: the build VM (Ubuntu, `qemu-system-x86`, `ovmf`, `/dev/kvm`). Everything
runs from the repo checkout; `E2E_DIR` (default `/tmp/e2e`) holds the disk
image, firmware vars, QMP socket, logs and screenshots. Screenshots are PNG
files you look at; coordinates below are for the 1280x800 guest screen and
the 2026-09-05 layout, so re-check them against a fresh screenshot.

## 1. Boot the ISO

```sh
cd ~/ASTRO-OS
rm -f /tmp/e2e/disk.qcow2                     # clean machine
bash astroos/scripts/e2e/e2e-start.sh iso out/astroos-desktop-linux-<date>.iso
sleep 20; python3 astroos/scripts/e2e/e2e.py shot /tmp/e2e/s01.png   # GRUB menu
python3 astroos/scripts/e2e/e2e.py key ret                            # first entry
sleep 100; python3 astroos/scripts/e2e/e2e.py shot /tmp/e2e/s02.png  # Plasma + Welcome Center
```

## 2. ssh into the live guest

Open Konsole from the panel (bottom-left icons: Konsole was at 208,784), then
type the key and start sshd (liveuser has passwordless sudo on the live ISO):

```sh
e=astroos/scripts/e2e/e2e.py
python3 $e click 208 784; sleep 4
python3 $e type "mkdir -p ~/.ssh; echo '$(cat ~/.ssh/id_ed25519.pub)' > ~/.ssh/authorized_keys; sudo systemctl start sshd
"
python3 $e hmp hostfwd_add n0 tcp::2222-:22
ssh -p 2222 liveuser@127.0.0.1 hostname          # astroos
```

## 3. Launch the installer

`guest-launch.sh` first asserts that calamares has no missing libraries, then
starts the shipped launcher (`/usr/local/bin/calamares-online.sh`, the one the
Welcome Center button and the menu entry run) inside the Plasma session:

```sh
ssh -p 2222 liveuser@127.0.0.1 bash -s < astroos/scripts/e2e/guest-launch.sh
```

The installer log is `~/astroos-install.log` in the guest (`calamares -D6`).
The Welcome Center's own button does the same thing; clicking it is a fair
alternative once you have a screenshot to aim at.

## 4. Drive the pages

Take a screenshot, click, repeat. Order on 2026-09-05: Welcome (Next) ->
Location (timezone map or list) -> Keyboard -> Bootloader (Limine) ->
Partitions (Erase disk, btrfs) -> Desktop (Plasma) -> Packages (the eight
AstroOS groups are preselected; BlackArch tools is a group when the ISO was
built with it) -> Users (name, login, hostname `astroos-e2e`, password twice)
-> Summary -> Install -> "Install Now" in the confirmation dialog.
Text fields: click the field, then `e2e.py type "..."`; `e2e.py key tab`
moves on. Keep every screenshot; they are the branding evidence.

## 5. Wait for the install

```sh
bash astroos/scripts/e2e/watch-install.sh 2222        # one line per 2 min
```

## 6. Give the installed system a way in, then boot it

Calamares unmounts the target when it finishes. From the live guest,
`guest-postinstall-ssh.sh` mounts the btrfs subvolumes, drops liveuser's key
into the new user's home and enables sshd:

```sh
ssh -p 2222 liveuser@127.0.0.1 'bash -s USER' < astroos/scripts/e2e/guest-postinstall-ssh.sh
python3 astroos/scripts/e2e/e2e.py quit
bash astroos/scripts/e2e/e2e-start.sh disk
sleep 60; python3 astroos/scripts/e2e/e2e.py shot /tmp/e2e/d01.png    # login screen
python3 astroos/scripts/e2e/e2e.py hmp hostfwd_add n0 tcp::2222-:22
E2E_PASS=<password> ssh -p 2222 USER@127.0.0.1 'E2E_PASS='"'"'<password>'"'"' bash -s' < astroos/scripts/e2e/verify-installed.sh
```

Then log in on the screenshot (click the password field, type it, Enter) and
screenshot the desktop: Kickoff icon, wallpaper, Konsole greeting.

Notes from the 2026-09-05 run. The live session's sshd stopped answering
once the installer had filled the RAM-backed overlay with its package cache;
if step 6 cannot reach the guest, power it off and use the host-side
`sudo host-inject-ssh.sh USER` (qemu-nbd) instead. The installed system runs
ufw with incoming denied, so after the first login open Konsole and run
`sudo ufw allow 22/tcp` before the ssh step; the user's login shell is fish
(CachyOS default), so remote commands go through `bash -s` with the script
on stdin, as `verify-installed.sh` does.

## 7. Clean up

`e2e.py quit`, then delete `/tmp/e2e` (the 40 GB image lives there).
