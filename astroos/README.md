# AstroOS — archiso build profile

The declarative definition of AstroOS. The ISO is the *output* of this repo, not a
separate phase. See `../ASTROOS-SPEC.md` for the full manifest and `../COUNCIL_LEDGER.md`
for design decisions.

## Layout

```
astroos/
├── profiledef.sh          # archiso profile (iso name, boot modes, perms)
├── pacman.conf            # build-time pacman config (add cachyos + blackarch repos here)
├── packages.x86_64        # GENERATED — do not hand-edit (scripts/gen-packages.sh)
├── meta/                  # SOURCE OF TRUTH: one .list per bucket
│   ├── astroos-core.list        # everyday base + convenience + perf daemons
│   ├── astroos-astro.list       # hardware-free astro identity (core)
│   ├── astroos-continuity.list  # AirDrop / mirroring / machine-to-machine
│   ├── astroos-hacking.list     # curated security essentials
│   ├── astroos-research.list    # physics / scicomp / datascience / viz / writing
│   └── aur.list                 # AUR pkgs (chroot bootstrap, not mkarchiso pacman)
├── airootfs/              # overlay: everything under / on the live system
│   └── usr/local/bin/astroos-doctor
└── scripts/
    ├── gen-packages.sh    # meta/*.list -> packages.x86_64 (dedupe + provenance)
    ├── build-iso.sh       # containerized mkarchiso + reproducibility artifacts
    └── qemu-smoke.sh      # boot the ISO in QEMU, assert boot + targets
```

## Build loop (no Claude tokens needed — you run these)

```sh
bash astroos/scripts/gen-packages.sh     # refresh package list after editing meta/
bash astroos/scripts/build-iso.sh        # build the ISO (needs docker/podman)
bash astroos/scripts/qemu-smoke.sh       # boot-test the result
```

The build runs the Arch toolchain inside a container, so the **host does not need to
be Arch/CachyOS** — docker or podman is enough. To iterate on the live daily-driver
instead of the ISO, install CachyOS, add packages, and write every change back into
`meta/` (the governing principle in the spec).

## TODO before first real build

- [ ] `pacman.conf`: add cachyos-v3/v4 repos + BlackArch repo blocks.
- [ ] `airootfs/`: KDE defaults, branding, snapper config, zram config, systemd services.
- [ ] AUR bootstrap hook (opendrop/owl, normcap, astromatic) via `airootfs` customize script.
- [ ] Pin `BUILDER_IMAGE` to a `@sha256:` digest in `build-iso.sh`.
