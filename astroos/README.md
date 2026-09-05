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
│   ├── aur.list                 scope of the signed [astroos] repo (built from the AUR, see below)
│   └── blackarch.list           packages from [blackarch]; appended only with ASTROOS_WITH_BLACKARCH=1
├── aur-patches/<pkg>/*.sh     tracked PKGBUILD fixes for stale AUR recipes, recorded in aur-map.lock (R3 D6)
├── overlay/airootfs/          the delta under /: identity files, alpm hooks, astroos-* tools, repo keyring,
│                              fastfetch + fish drop-ins, wallpaper package, smoke unit
├── branding/                  logo masters + assetgen.py; out/ = generated icons, splashes, wallpaper, watermark, ANSI logo
├── releases/<date>/           promotion + release manifests written by forge-remote.sh (R3 D5)
├── KEYS.md                    repo signing key: generation, offline backup, rotation
└── scripts/
    ├── gen-packages.sh        meta/*.list -> astroos-additions.x86_64 (dedupe, provenance headers, zero-package hard fail)
    ├── build-iso.sh           host side: builder container, reproducibility artifacts, ISO size gate
    ├── container-build.sh     inside archlinux:base-devel: clone the base, apply deltas 1-3, run CachyOS's buildiso.sh
    ├── qemu-smoke.sh          boot gate: direct-kernel boot of the ISO's kernel, five in-guest verdicts
    ├── build-aur-repo.sh      the [astroos] repo: preflight | build | publish | keygen
    ├── forge.sh               VM pipeline: repo publish verify iso gate audit release
    └── forge-remote.sh        laptop driver: start VM, sync HEAD, run forge.sh, stream, collect, record, deallocate
```

## How a build works

`container-build.sh`, inside the builder container:

1. installs archiso and tooling, imports the CachyOS signing key, clones CachyOS-Live-ISO at the commit in `base.lock`
2. **delta 1, packages:** appends `astroos-additions.x86_64` to their desktop list, deduped against the base; hard-fails below `ASTROOS_MIN_ADDITIONS` (a base-only ISO would still pass the boot gate)
3. **delta 2, overlay:** copies `overlay/airootfs`; **2b, branding:** installs the generated assets, writes the plymouth watermark hook, masks CachyOS's identity-rewriting hooks, swaps bootloader splashes and menu titles
4. **delta 2c, `[astroos]` repo** (`ASTROOS_WITH_AUR_REPO=1`, the default in forge.sh): asserts the shipped keyring fingerprint, checks that the hosted repo db carries exactly the `aur.list` names (D4), adds the repo to the build and shipped `pacman.conf`, appends the scope to the package list
5. **delta 2d, `[blackarch]`** (`ASTROOS_WITH_BLACKARCH=1`): fetches the keyring tarball, verifies it against `blackarch-keyring.lock`, populates it, appends the repo *after* the Arch repos in both configs, appends `meta/blackarch.list`
6. overlay preflight (mask symlinks, executables, hooks, assets all present), identity edits to `profiledef.sh`, then their `buildiso.sh` unchanged apart from three one-line patches

Output in `out/`: the ISO, `manifest.pkglist`, `build-metadata.txt`, `sha256sums.txt`.

**Package-owned paths are never pre-placed in the overlay.** mkarchiso copies the overlay *before* pacstrap, and pacman refuses the resulting file conflict (`NoExtract` does not exempt a path). Such files (plymouth watermark, `os-release`, installer branding) are staged under `/usr/share/astroos/branding/` and applied by alpm PostTransaction hooks, which also keep installed systems branded across upgrades.

## Release pipeline (the normal way to build)

From the laptop, with `az` logged in and an ssh key for the VM user:

```sh
bash astroos/scripts/forge-remote.sh                        # everything: repo publish verify iso gate audit release
bash astroos/scripts/forge-remote.sh iso gate audit release # a new ISO from the already-published repo
bash astroos/scripts/forge-remote.sh --keep-vm repo publish verify
```

Every stage is idempotent, so a failed run is rerun from the failed stage. Stage lines stream to the terminal; artifacts land in `out/forge-<stamp>/`, manifests in `astroos/releases/<date>/`, and the VM is deallocated at the end (a guest shutdown still bills; only deallocation stops the meter).

Hosting: ISOs at `https://astroosrepo.blob.core.windows.net/repo/iso/<name>/` (`iso/LATEST` names the newest) with sha256 and a detached signature by the repo key; the package repo at `.../repo/astroos/x86_64`.

## The `[astroos]` repo

The `aur.list` scope is built from the AUR, one package per fresh container in topological order (contamination impossible by construction, R3 D1), signed with the AstroOS key (`KEYS.md`; fingerprint in `branding/REPO_FINGERPRINT`), and published packages-first, db-last. Preflights on every run: scope count equals `ASTROOS_AUR_SCOPE`, every name still resolves in the AUR, none has migrated to the official repos (a name that reaches `[extra]` leaves the lane, as `informant` did). Python packages must pass an import smoke in a fresh container; build and smoke failures are recorded and block signing. `aur-map.lock` (AUR commit, pkgver, sources and checksums, patches applied) is published signed beside the db. Client trust: `SigLevel = Required DatabaseOptional` for publish cycle 1, full `Required` from cycle 2 (ledger).

## Iterating on the laptop

```sh
bash astroos/scripts/gen-packages.sh                 # after editing meta/
bash astroos/scripts/build-aur-repo.sh preflight     # scope + liveness + migration (needs podman)
```

CI (`.github/workflows/checks.yml`) runs shellcheck, the generated-list currency check and the preflight on every push, and the preflight weekly as the standing AUR liveness check. The ISO build itself needs a Linux host with podman and KVM: that is the Azure VM (`astroos-forge`). WSL is never used on this laptop (R1.2).

## Verification levels

1. **Boot gate** (`qemu-smoke.sh`): kernel + archiso initramfs, getty, graphical target, network online, `astroos-doctor --quick`.
2. **Content audit** (`forge.sh audit`): inside the squashfs: identity files, branding asset hashes, hook masks, repo wiring and keyring, every scope package and every addition present in the pacman local db, boot menu titles.
3. **Hosted repo verify** (`forge.sh verify`): db, files and lock signatures against the *shipped* keyring, D4 name set, and a fresh client installing real packages under `SigLevel Required`.

Owner-side, not automatable: one Calamares install in a VM (Calamares has no unattended mode) and visual QA on real hardware.
