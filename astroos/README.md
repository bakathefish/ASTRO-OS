# AstroOS — build definition

AstroOS is CachyOS plus a declared delta. The ISO is the *output* of this
directory, never a hand-tuned system. `../ASTROOS-SPEC.md` is the manifest;
`../COUNCIL_LEDGER.md` records every design decision and why.

## Layout

```
astroos/
├── base.lock                  CachyOS-Live-ISO repo + commit the ISO is built from (R1.2: lift, don't rebuild)
├── blackarch-keyring.lock     BlackArch keyring version + sha256 pin (delta 2d)
├── astroos-additions.x86_64   GENERATED from meta/ by scripts/gen-packages.sh — never hand-edited
├── meta/                      SOURCE OF TRUTH: one list per bucket
│   ├── astroos-core.list        everyday base, convenience layer, reliability daemons
│   ├── astroos-astro.list       sky, FITS tools, astrophoto (hardware-free)
│   ├── astroos-continuity.list  LocalSend, KDE Connect, input-leap, syncthing, scrcpy
│   ├── astroos-hacking.list     curated security tools from [extra]
│   ├── astroos-research.list    physics, scicomp, data science, viz, writing
│   ├── astroos-laptop.list      sensors, on-screen keyboard, Intel media/Vulkan/NPU, asusctl
│   ├── aur.list                 the AUR part of the signed [astroos] repo (see below)
│   └── blackarch.list           packages from [blackarch]; appended only with ASTROOS_WITH_BLACKARCH=1
├── pkgs/<name>/               AstroOS's OWN packages, built into the [astroos] repo next to the AUR scope
│   ├── astroos-keyring          pacman keyring trio (astroos.gpg, astroos-trusted, astroos-revoked) + populate on install
│   ├── astroos-branding         identity files, icons, wallpaper (desktop, SDDM and plasmalogin greeters),
│   │                            plymouth watermark, fastfetch/fish drop-ins, alpm hooks that re-assert
│   │                            identity and mask CachyOS's identity hooks
│   ├── astroos-tools            astroos-doctor, astroos-cuda-setup, astroos-hacking-heavy
│   ├── astroos-calamares        installer branding component + the hook that re-points cachyos-calamares-next
│   ├── astroos-calamares-boost-compat  the three boost 1.91 runtime libs the installer still links (live ISO only, temporary)
│   └── astroos-zenbook-duo      ASUS Zenbook Duo profile (DMI-gated; zakstam/zenbook-duo-linux runtime)
├── aur-patches/<pkg>/*.sh     tracked PKGBUILD fixes for stale AUR recipes, recorded in aur-map.lock (R3 D6)
├── overlay/airootfs/          LIVE-SESSION-ONLY files: hostname, live os-release/issue, plymouthd.conf,
│                              plasma-welcome install button, installer launcher, smoke unit
├── branding/                  logo masters + assetgen.py; out/ = icons, splashes, wallpaper (+preview), watermark,
│                              ANSI logo, calamares/ (logo, icon, welcome, three slides)
├── releases/<date>/           promotion + release manifests written by forge-remote.sh (R3 D5)
├── KEYS.md                    repo signing key: generation, backup, client trust path, rotation
└── scripts/
    ├── gen-packages.sh        meta/*.list -> astroos-additions.x86_64 (dedupe, provenance headers, zero-package hard fail)
    ├── build-iso.sh           host side: builder container, reproducibility artifacts, ISO size gate
    ├── container-build.sh     inside archlinux:base-devel: clone the base, apply deltas 1-3, run CachyOS's buildiso.sh
    ├── qemu-smoke.sh          boot gate: direct-kernel boot of the ISO's kernel, five in-guest verdicts
    ├── build-aur-repo.sh      the [astroos] repo: keygen | preflight | build | local <name> | publish | all
    ├── forge.sh               VM pipeline: repo publish verify iso gate audit release
    └── forge-remote.sh        laptop driver: start VM, sync HEAD, run forge.sh, stream, collect, record, deallocate
```

## Why the identity is a set of packages

CachyOS's Calamares is an *online* installer: it pacstraps the target from the
repositories and then installs netinstall groups. Nothing in the live overlay
reaches the installed system. Only `/etc/pacman-more.conf` (copied as the
target's `pacman.conf`), the mirrorlists, the pacman keyring and
`mkinitcpio.conf` cross over. So every AstroOS surface that must exist on an
installed system is a package in the signed `[astroos]` repo:

- `astroos-keyring` makes the repo trusted on live and installed systems.
- `astroos-branding` ships the identity files and assets under
  `/usr/share/astroos/` plus alpm hooks: PostTransaction hooks re-assert
  `os-release`, `lsb-release`, `issue`, `motd`, the plymouth watermark and the
  KDE skel edits whenever CachyOS's own packages rewrite them; same-name
  `/dev/null` symlinks in `/etc/pacman.d/hooks` mask CachyOS's identity hooks.
  Package-owned paths are never shipped twice.
- `astroos-calamares` ships the branding component and a hook that rewrites
  `cachyos-calamares-next`'s configuration in place (branding name, package
  lists, bootloader id and splash, plymouth theme, the pacstrap base set,
  which now carries the three astroos packages). The netinstall groups it
  appends are generated from `meta/*.list` at package build time, so the
  installed system gets the same package set as the live ISO.
- `astroos-calamares-boost-compat` is a temporary shim. `cachyos-calamares-next`
  3.4.2-13 still links three boost 1.91 libraries while `boost-libs` moved to
  1.92 hours after it was built, so on the first 2026-09-05 ISO the installer
  did not start at all (found by the end-to-end install test, not by the
  audit). The package ships exactly those three versioned files from the
  Arch Linux Archive; they coexist with 1.92. It is in no installer group, so
  installed systems never get it. Remove it once the installer is rebuilt
  against the current boost: `ldd /usr/bin/calamares` in the live ISO must
  report nothing missing (the end-to-end test asserts exactly that).
- `astroos-zenbook-duo` is a laptop profile that only activates when DMI says
  the machine is a UX8406MA/UX8406CA (override: `/etc/zenbook-duo/force`).
  It ships the zenbook-duo-linux runtime (dual-panel layout, keyboard
  attach/detach, orientation, brightness sync), a per-user session agent, an
  on-screen keyboard default, OLED power timers and the PSR-off modprobe
  applied on first boot. Notes in `/usr/share/doc/astroos/zenbook-duo.md`.

The live ISO installs the same packages from the hosted repo during
`mkarchiso`, so the live session and the installed system are branded by
the same bytes.

## How a build works

`container-build.sh`, inside the builder container:

1. installs archiso and tooling, imports the CachyOS signing key, clones CachyOS-Live-ISO at the commit in `base.lock`
2. **delta 1, packages:** appends `astroos-additions.x86_64` to their desktop list, deduped against the base; drops `cachyos-hello` and `cachyos-cli-installer-new`; hard-fails below `ASTROOS_MIN_ADDITIONS` (a base-only ISO would still pass the boot gate)
3. **delta 2, overlay:** copies the live-only `overlay/airootfs`; **2b, bootloader branding:** swaps the GRUB, syslinux and Limine splashes and menu titles at profile level
4. **delta 2c, `[astroos]` repo** (`ASTROOS_WITH_AUR_REPO=1`, required unless `ASTROOS_ALLOW_UNBRANDED=1`): installs the keyring trio from `pkgs/astroos-keyring` into the builder, asserts the fingerprint and the trusted line, populates it, checks that the hosted db carries exactly the `aur.list` names plus the `pkgs/` names (D4), appends the repo *after* the Arch repos in the build `pacman.conf`, the live `pacman.conf` and `pacman-more.conf`, and appends the whole scope to the package list
5. **delta 2d, `[blackarch]`** (`ASTROOS_WITH_BLACKARCH=1`): fetches the keyring tarball, verifies it against `blackarch-keyring.lock`, populates it, appends the repo after `[astroos]` in all three configs, appends `meta/blackarch.list`
6. overlay preflight (every expected live file present, no package-owned path in the overlay), identity edits to `profiledef.sh`, then their `buildiso.sh` unchanged apart from four one-line patches (their exit trap, the ISO file name, the profile variable, motd generation off)

Output in `out/`: the ISO, `manifest.pkglist`, `build-metadata.txt`, `sha256sums.txt`.

**Package-owned paths are never pre-placed in the overlay.** mkarchiso copies the overlay *before* pacstrap, and pacman refuses the resulting file conflict (`NoExtract` does not exempt a path). The preflight fails the build if such a path appears in `overlay/`; the packages above own them.

## Release pipeline (the normal way to build)

From the laptop, with `az` logged in and an ssh key for the VM user:

```sh
bash astroos/scripts/forge-remote.sh                        # everything: repo publish verify iso gate audit release
bash astroos/scripts/forge-remote.sh iso gate audit release # a new ISO from the already-published repo
bash astroos/scripts/forge-remote.sh --keep-vm repo publish verify
```

Every stage is idempotent, so a failed run is rerun from the failed stage. Stage lines stream to the terminal; artifacts land in `out/forge-<stamp>/`, manifests in `astroos/releases/<date>/`, and the VM is deallocated at the end (a guest shutdown still bills; only deallocation stops the meter). A run identity (`out/RUN_START`) ties the release record to the run that produced it; a stale ISO can not be recorded as a release.

Hosting: ISOs in the public `iso` container at `https://astroosrepo.blob.core.windows.net/iso/<name>-<commit>/` (`iso/LATEST` names the newest) with its sha256, the build metadata, the package manifest, the audit report, the release record and an armored detached signature (`.iso.asc`) by the repo key; the package repo at `https://astroosrepo.blob.core.windows.net/repo/astroos/x86_64`.

## The `[astroos]` repo

The repo holds two kinds of packages. The `aur.list` scope is built from the AUR, one package per fresh container in topological order (contamination impossible by construction, R3 D1). The `pkgs/` directory holds AstroOS's own packages, built the same way; their version is the UTC timestamp of the last commit that touched their inputs (the package directory, and for the branding and installer packages `branding/out` and `meta/`), so a rebuild happens only when something they ship changed. Everything is signed with the AstroOS key (`KEYS.md`; fingerprint in `branding/REPO_FINGERPRINT`) and published packages-first, db-last.

Preflights on every run: scope count equals `ASTROOS_AUR_SCOPE`, every AUR name still resolves (liveness), none has migrated to the official repos (a name that reaches `[extra]` leaves the lane, as `informant` did), and the `pkgs/` names never collide with the AUR scope. Python packages must pass an import smoke in a fresh container; build and smoke failures are recorded and block signing and publishing. `aur-map.lock` (AUR commit, pkgver as built, sources and checksums before patching, VCS commits for `-git` packages, patches applied) is published signed beside the db. Client trust: `SigLevel = Required DatabaseOptional` for publish cycle 1, full `Required` from cycle 2 (ledger R4.1 carries the date).

## Iterating on the laptop

```sh
bash astroos/scripts/gen-packages.sh                 # after editing meta/
bash astroos/scripts/build-aur-repo.sh preflight     # scope + liveness + migration (needs podman)
python astroos/branding/assetgen.py astroos/branding/logo-sr.png astroos/branding/out   # after a new logo master
```

On the VM, one local package at a time: `bash astroos/scripts/build-aur-repo.sh local astroos-branding`.

CI (`.github/workflows/checks.yml`) has three jobs: `lint` (shellcheck and `bash -n` over every script, PKGBUILD helper and hook binary, plus the generated-list currency check) and `aur-scope` (the preflight) on every push, and `hosted-repo` on the weekly schedule or by hand: a fresh Arch container trusts the shipped keyring, resolves the whole scope from the hosted repo and installs real packages. The ISO build itself needs a Linux host with podman and KVM: that is the Azure VM (`astroos-forge`). WSL is never used on this laptop (R1.2).

## Verification levels

1. **Boot gate** (`qemu-smoke.sh`): kernel + archiso initramfs, getty, graphical target, network online, `astroos-doctor --quick`.
2. **Content audit** (`forge.sh audit`): inside the squashfs: identity files and hostname, motd, plymouth watermark hash, hook masks and re-assertion hooks, CachyOS hello removed, the installer launcher, `[astroos]` and its keyring in both pacman configs, the BlackArch wiring when enabled, the installer re-pointing (branding component, package lists, base set), the Zenbook Duo runtime and defaults, every scope package and every addition in the pacman local db, boot menu titles.
3. **Hosted repo verify** (`forge.sh verify`): db, files and lock signatures against the *shipped* keyring, D4 name set, and a fresh client installing the five astroos packages and a sample of the AUR builds under `SigLevel Required`.

4. **End-to-end install** (`scripts/e2e/`, runbook in its README): the release ISO boots a headless KVM guest through its own GRUB menu into Plasma; `ldd /usr/bin/calamares` must report nothing missing; the Welcome Center's Install icon is clicked over QMP and the real installer is driven page by page (screenshots, clicks, typed text) through an online install of every AstroOS group plus BlackArch onto a blank disk; the installed disk is booted and `verify-installed.sh` asserts identity, motd, hostname, terminal greetings, the login-screen wallpaper, `[astroos]` and `[blackarch]` wiring and trust, the AstroOS packages, hooks, masks, services and `astroos-doctor`. Calamares has no unattended mode, so this is how the install path gets tested at all; it found the boost mismatch, the Welcome Center button and the locale failure on 2026-09-05, none of which the content audit could see.

Owner-side, not automatable: the first boot of an install on the Zenbook Duo (panel layout, keyboard detach, rotation, on-screen keyboard), and visual QA of the branding on real hardware.

## Install and first boot

**Download.** `https://astroosrepo.blob.core.windows.net/iso/LATEST` is one line: the directory of the newest release. Under `https://astroosrepo.blob.core.windows.net/iso/<that line>/` sit the ISO, its `.sha256`, its `.asc` (armored signature by the repo key), `RELEASE`, `build-metadata.txt`, `manifest.pkglist` and `audit.txt`. Verify before flashing:

```sh
sha256sum -c astroos-desktop-linux-<date>.iso.sha256
curl -fsSLO https://astroosrepo.blob.core.windows.net/repo/astroos/astroos.gpg
gpg --import astroos.gpg      # the fingerprint must read DA5C947A5C329E528948830E92304756ECC2F9D8
gpg --verify astroos-desktop-linux-<date>.iso.asc astroos-desktop-linux-<date>.iso
```

**Flash and boot.** Ventoy, Rufus in dd mode, or `dd bs=4M status=progress conv=fsync` on Linux. Boot with Secure Boot disabled, as the CachyOS base requires. The live session comes up as `astroos` with the AstroOS identity everywhere the base showed CachyOS.

**Install.** The installer needs a network connection: it pacstraps the target from the repositories. Start "Install AstroOS" from the application menu or the welcome window. Calamares shows the AstroOS branding and package groups: the identity packages are a hidden mandatory group; core, astro, continuity, hacking, research, laptop and the AUR-built scope are visible groups, all preselected, all critical like CachyOS's own groups (an install does not silently drop packages). The BlackArch group appears only on an ISO built with it. Bootloader, filesystem and kernel choices are CachyOS's; Limine carries the AstroOS splash.

**First boot.** The installed system is branded by the same packages as the live ISO, and stays branded across upgrades because the hooks re-assert it. On a Zenbook Duo the profile activates by itself: the first boot disables Panel Self Refresh and rebuilds the initramfs, so reboot once more; the panel daemon binds to the first regular account (edit `/etc/zenbook-duo/env` to change it). Everything else about the Duo, including the known upstream gaps, is in `/usr/share/doc/astroos/zenbook-duo.md`. On any other machine the Duo services stay inert.

**Every day.** `sudo pacman -Syu` updates Arch, CachyOS and `[astroos]` together (and `[blackarch]` when enabled); the reboot-required notifier says when a kernel or core update wants a restart. `astroos-doctor` prints a health report worth pasting into a bug report. `sudo astroos-hacking-heavy --install` fetches the large security tools (Burp Suite, SecLists, Metasploit, ZAP) on demand; `--list` shows them. `astroos-cuda-setup` sets up CUDA on NVIDIA machines.
