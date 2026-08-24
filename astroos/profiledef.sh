#!/usr/bin/env bash
# shellcheck disable=SC2034
# AstroOS archiso profile definition.
# Boot plumbing (bootmodes, efiboot/, syslinux/, grub/, pacman.conf skeleton)
# is grafted from archiso's releng profile (archiso 89-1); keep in sync with
# upstream when bumping the pinned builder image.
# Docs: https://gitlab.archlinux.org/archlinux/archiso

iso_name="astroos"
# FAT label limit is 11 chars (the EFI boot image uses this) — keep it short.
iso_label="ASTROOS$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%y%m)"
iso_publisher="AstroOS <https://github.com/PLACEHOLDER/astroos>"
iso_application="AstroOS Live/Install Medium"
iso_version="0.1.0-dev"
install_dir="astroos"
buildmodes=('iso')
bootmodes=('bios.syslinux'
           'uefi.systemd-boot')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '19' '-b' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')

# File permissions/ownership for overlay files that need them.
# releng entries first, AstroOS additions after.
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/Installation_guide"]="0:0:755"
  ["/usr/local/bin/livecd-sound"]="0:0:755"
  ["/usr/local/bin/astroos-doctor"]="0:0:755"
  ["/usr/local/bin/astroos-upgrade"]="0:0:755"
)
