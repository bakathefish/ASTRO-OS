# AstroOS

A research and astronomy workstation built on Arch Linux. KDE Plasma, a signed
package repository of its own, and the scientific and security toolchains ready
on first boot. Fast where CachyOS is fast, branded end to end, and independent:
every system package is built and signed under AstroOS's own key.

![The AstroOS desktop](docs/screenshots/first-boot.png)

## Get it

**[Read the install guide (INSTALL.md)](INSTALL.md)** for the full walkthrough
with screenshots: download, verify, flash, boot and install.

The newest release is always named in one line at
`https://astroosrepo.blob.core.windows.net/iso/LATEST`; the image, its
checksum and its signature sit in the directory that line names. Verify the
signature against the AstroOS release key before flashing:

```
DA5C 947A 5C32 9E52 8948  8302 3923 0475 6ECC 2F9D 8
```

You can run AstroOS straight from the USB stick to try it, or install it to
disk from the same session.

> **Closed beta.** This is a pre-release shared for testing. Expect rough
> edges, keep backups, and please report anything that looks wrong. Start with
> `astroos-doctor` for a health report to attach.

## What is inside

- **KDE Plasma 6** on Wayland, themed in the AstroOS palette from the boot menu
  to the lock screen.
- **Astronomy and science**: the AstrOmatic pipeline, gnuastro, HEALPix, SunPy,
  astroML, emcee, Qiskit, QuTiP, Geant4, TOPCAT, DS9, Siril, Veusz and more.
- **Security toolchain** with an optional BlackArch build and on demand heavy
  tools (Burp Suite, Metasploit, SecLists, ZAP).
- **Its own signed `[astroos]` repository** carrying every AstroOS package plus
  the AUR built scope, and the **`linux-astroos`** and **`linux-astroos-lts`**
  kernels.
- **Continuity**: native AirDrop send and receive, LocalSend, and desktop
  integration out of the box.
- A branded **Calamares** installer with GRUB, rEFInd, systemd-boot and Limine,
  Btrfs snapshots, and full disk encryption.

## A look around

| | |
|---|---|
| ![Boot menu](docs/screenshots/boot-menu.png) | ![Login screen](docs/screenshots/login.png) |
| The boot menu | The login screen |
| ![Application menu](docs/screenshots/app-menu.png) | ![Terminal](docs/screenshots/terminal.png) |
| The application menu | The terminal greeting |
| ![Installer](docs/screenshots/installer-6-desktop.png) | ![Installer summary](docs/screenshots/installer-8-summary.png) |
| Choosing a desktop | The install summary |

## How it is built

AstroOS is defined as a set of packages and build scripts, not a fork. The
`astroos/` directory holds everything: the branding, the package recipes, the
Calamares configuration and the forge pipeline that produces the signed repo
and the ISO. See **[astroos/README.md](astroos/README.md)** for the build
definition, the release pipeline and how the identity is layered on top of the
Arch and CachyOS bases.

## License

The AstroOS packaging, branding and scripts are under the licenses named in
each package. AstroOS builds on Arch Linux and CachyOS and ships the upstream
projects under their own licenses.
