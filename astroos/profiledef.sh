#!/usr/bin/env bash
# shellcheck disable=SC2034
# AstroOS archiso profile definition.
# Docs: https://gitlab.archlinux.org/archlinux/archiso

iso_name="astroos"
iso_label="ASTROOS_$(date +%Y%m 2>/dev/null || echo 000000)"
iso_publisher="AstroOS <https://github.com/PLACEHOLDER/astroos>"
iso_application="AstroOS Live/Install Medium"
iso_version="0.1.0-dev"
install_dir="astroos"
buildmodes=('iso')
bootmodes=('bios.syslinux.mbr' 'bios.syslinux.eltorito'
           'uefi-ia32.systemd-boot.esp' 'uefi-x64.systemd-boot.esp'
           'uefi-ia32.systemd-boot.eltorito' 'uefi-x64.systemd-boot.eltorito')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '19' '-b' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '-19')

# File permissions/ownership for overlay files that need them.
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/usr/local/bin/astroos-doctor"]="0:0:755"
  ["/usr/local/bin/astroos-upgrade"]="0:0:755"
)
