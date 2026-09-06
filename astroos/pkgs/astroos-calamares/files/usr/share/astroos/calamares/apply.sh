#!/usr/bin/env bash
# Re-points the Calamares configuration that astroos-calamares-installer ships
# at AstroOS. Runs as an alpm PostTransaction hook whenever
# astroos-calamares-installer (or astroos-calamares) is installed or upgraded,
# so the installer package itself is never forked: every edit is a targeted,
# idempotent sed on its shipped file, plus two whole-file replacements
# (netinstall.conf, plymouthcfg.conf) and one append (the AstroOS package
# groups). Survey: .planning/R4_BRANDING_SURVEY.md sections 0 and 2.
#
# Every sed below was checked against the source astroos-calamares-installer
# pins, CachyOS/cachyos-calamares commit ce54421cf0a08008ccda59a4e5f2f4747ae762be
# (tarball sha256 6b4b721f08f1eea6743fe57a4f01e4bb4b343cf412eb853a30966f8b18741b47,
# the sha256sums entry in astroos-calamares-installer/PKGBUILD). Moving that pin
# means re-checking every anchor here.
#
# Exit status is always 0 (a hook failure would abort every pacman run); a
# surviving CachyOS surface is reported as a WARNING line for the build log,
# and the forge audit asserts the result inside the ISO.
set -u
d=/usr/share/astroos/calamares
m=/etc/calamares/modules
s=/etc/calamares/scripts
py=/usr/lib/calamares/modules
[[ -d $m ]] || exit 0

warn() { echo "astroos-calamares: WARNING: $1" >&2; }

# The CachyOS package names the installer hard-codes, and the AstroOS package
# that replaces each one; "-" means AstroOS has no counterpart and the entry is
# dropped. Same table for netinstall.yaml and pacstrap.conf, which are both
# YAML sequences of bare package names. The right column is the same map
# astroos/scripts/container-build.sh applies to the ISO package list.
_pkgmap() {
  cat <<'MAP'
cachyos-hooks                   astroos-hooks
cachyos-keyring                 astroos-keyring
cachyos-mirrorlist              astroos-mirrorlist
cachyos-v3-mirrorlist           astroos-v3-mirrorlist
cachyos-v4-mirrorlist           astroos-v4-mirrorlist
cachyos-rate-mirrors            astroos-rate-mirrors
cachyos-settings                astroos-settings
cachyos-kde-settings            astroos-kde-settings
cachyos-fish-config             astroos-fish-config
chwd                            astroos-chwd
linux-cachyos                   linux-astroos
linux-cachyos-headers           linux-astroos-headers
linux-cachyos-lts               linux-astroos-lts
linux-cachyos-lts-headers       linux-astroos-lts-headers
# AstroOS has no handheld kernel; the handheld group gets the ordinary one
# rather than emptying out (an empty packages: list is not valid here)
linux-cachyos-deckify           linux-astroos
linux-cachyos-deckify-headers   linux-astroos-headers
# Names only [cachyos] served, inside groups upstream ships under other
# names. Measured 2026-09-06 inside the live ISO: pacman -Sp over every name
# in netinstall.yaml against core, extra, multilib, astroos and blackarch
# left exactly these (firefox-i18n-$LOCALE aside, which the installer
# substitutes). Two of them, char-white (KDE-Desktop) and shelly (packages
# management), sat in the default selection and made every install fail at
# pacstrap with "target not found"; the audit's resolver simulation only
# covers that default selection, so the five in optional desktop groups are
# listed from the same measurement. Dropped rather than mapped: each is one
# optional component of a desktop AstroOS does not preconfigure.
char-white                      -
shelly                          -
i3lock-color                    -
noctalia-greeter                -
wayfire-desktop-git             -
wired                           -
xcursor-neutral                 -
# CachyOS-only apps, themes, wallpapers and shell configs: dropped
cachy-update                    -
cachyos-emerald-kde-theme-git   -
cachyos-gnome-settings          -
cachyos-handheld                -
cachyos-hello                   -
cachyos-hypr-noctalia           -
cachyos-i3wm-settings           -
cachyos-iridescent-kde          -
cachyos-kernel-manager          -
cachyos-mango-noctalia          -
cachyos-micro-settings          -
cachyos-niri-noctalia           -
cachyos-nord-kde-theme-git      -
cachyos-packageinstaller        -
cachyos-picom-config            -
cachyos-plymouth-bootanimation  -
cachyos-plymouth-theme          -
cachyos-qtile-settings          -
cachyos-wallpapers              -
cachyos-wayfire-settings        -
cachyos-zsh-config              -
MAP
}

# apply _pkgmap to one YAML file, one sequence entry ("  - name") per line
_map_pkgs() {
  local f=$1 old new
  [[ -f $f ]] || return 0
  while read -r old new; do
    [[ -n $old && $old != \#* ]] || continue
    if [[ $new == - ]]; then
      sed -i "/^[[:space:]]*-[[:space:]]*${old}[[:space:]]*\$/d" "$f"
    else
      sed -i "s/^\([[:space:]]*-[[:space:]]*\)${old}[[:space:]]*\$/\1${new}/" "$f"
    fi
  done < <(_pkgmap)
}

# 1. branding component: ours ships beside upstream's; the settings select it
for f in /usr/share/calamares/settings.conf /usr/share/calamares/settings_online.conf /usr/share/calamares/settings_offline.conf; do
  [[ -f $f ]] && sed -i 's/^branding:.*/branding: astroos/' "$f"
done

# 2. package lists. netinstall.conf: local groups file ONLY (upstream lists a
#    GitHub URL first, which would let the installed set change after the ISO
#    ships). netinstall.yaml: every CachyOS package name mapped or dropped
#    (_pkgmap), capitalised brand in group titles, AstroOS groups appended
#    (generated from astroos/meta at package build time).
install -m644 "$d/netinstall.conf" "$m/netinstall.conf"
y=$m/netinstall.yaml
if [[ -f $y ]]; then
  _map_pkgs "$y"
  # the MangoWM entry names the dotfiles' origin in its English description and
  # in 12 translations: reword the English line and drop the translated ones so
  # Calamares falls back to it, then brand the rest of the file
  sed -i '/^- name: "MangoWM"/,/^- name: /{s/with CachyOS-provided dotfiles/with preconfigured dotfiles/; /^[[:space:]]*description\[/d;}' "$y"
  sed -i 's/CachyOS/AstroOS/g' "$y"
  grep -q '^- name: "AstroOS (hidden)"' "$y" || cat "$d/netinstall-astroos.yaml" >> "$y"
  # the BlackArch group only when the live system carries the repo (ISO flag)
  if grep -q '^\[blackarch\]' /etc/pacman.conf && ! grep -q '^- name: "BlackArch tools"' "$y"; then
    cat "$d/netinstall-blackarch.yaml" >> "$y"
  fi
fi

# 3. installer texts and installed-system defaults
sed -i 's/CachyOS/AstroOS/g' "$m/shellprocess-before-online.conf" "$m/shellprocess-before.conf" 2>/dev/null
# the package-owned copies the hook may rewrite: brand their descriptions too
for c in packagechooser_desktop.conf packagechooser_bootloader.conf welcome.conf welcome_online.conf; do
  [[ -f $m/$c ]] && sed -i 's/CachyOS/AstroOS/g' "$m/$c"
done
[[ -f $m/users.conf ]]      && sed -i 's/^\(\s*template:\s*\).*/\1"astroos"/' "$m/users.conf"
if [[ -f $m/bootloader.conf ]]; then
  # refindKernelList is the set of kernel names rEFInd is told to accept; the
  # upstream list is the CachyOS kernel flavours, none of which AstroOS ships,
  # so a rEFInd install would find no kernel at all
  sed -i \
    -e 's/^efiBootloaderId:.*/efiBootloaderId: "astroos"/' \
    -e 's|^limineSplashLogo:.*|limineSplashLogo: "/usr/share/astroos/branding/limine-splash.png"|' \
    -e 's/^refindKernelList:.*/refindKernelList: [ "linux-astroos","linux-astroos-lts","linux" ]/' \
    "$m/bootloader.conf"
fi
if [[ -f $m/grubcfg.conf ]]; then
  # The AstroOS GRUB theme (astroos-grub-theme, added to the pacstrap package
  # list in section 5) where upstream names the CachyOS one. Set, not deleted:
  # this is the menu the installed system boots into, and it is the same
  # theme.txt container-build.sh stages onto the live medium, so the two menus
  # cannot drift. GRUB_TOP_LEVEL names the kernel image GRUB should list first,
  # so it has to follow linux-cachyos -> linux-astroos.
  sed -i 's|^\(\s*GRUB_THEME:\).*|\1 "/usr/share/grub/themes/astroos/theme.txt"|' "$m/grubcfg.conf"
  grep -q '^\s*GRUB_THEME:' "$m/grubcfg.conf" \
    || sed -i 's|^\(\s*\)GRUB_TOP_LEVEL:.*|&\n\1GRUB_THEME: "/usr/share/grub/themes/astroos/theme.txt"|' "$m/grubcfg.conf"
  grep -q '^\s*GRUB_THEME: "/usr/share/grub/themes/astroos/theme.txt"$' "$m/grubcfg.conf" \
    || warn "grubcfg.conf does not select the AstroOS GRUB theme"
  sed -i 's|/boot/vmlinuz-linux-cachyos|/boot/vmlinuz-linux-astroos|' "$m/grubcfg.conf"
  # kept beside the theme: a theme's desktop-image wins over GRUB_BACKGROUND,
  # and the background line still covers a system whose theme fails to load
  grep -q '^\s*GRUB_BACKGROUND:' "$m/grubcfg.conf" \
    || sed -i 's|^\(\s*\)GRUB_TOP_LEVEL:.*|&\n\1GRUB_BACKGROUND: "/usr/share/astroos/branding/limine-splash.png"|' "$m/grubcfg.conf"
fi
install -m644 "$d/plymouthcfg.conf" "$m/plymouthcfg.conf"
[[ -f $m/welcome_online.conf ]] && sed -i 's|^\(\s*internetCheckUrl:\s*\).*|\1https://archlinux.org|' "$m/welcome_online.conf"
# the ZFS pool the installer creates is named in `zpool list` forever after
[[ -f $m/zfs.conf ]] && sed -i 's/^\(poolName:\s*\)zpcachyos\s*$/\1zpastroos/' "$m/zfs.conf"
# the offline sequence copies the kernel off the medium by filename. AstroOS
# ships linux-astroos, and container-build.sh rewrites -linux-cachyos ->
# -linux-astroos in every boot file, so the medium carries
# vmlinuz-linux-astroos{,-lts}. Both unpack entries are optional: true, so the
# deckify one stays a skip, exactly as it is today.
if [[ -f $m/unpackfs.conf ]]; then
  sed -i 's|vmlinuz-linux-cachyos|vmlinuz-linux-astroos|g' "$m/unpackfs.conf"
  grep -q cachyos "$m/unpackfs.conf" && warn "a cachyos kernel path survives in unpackfs.conf"
fi

# 3b. installer previews: the bootloader and desktop pages show AstroOS images
#     (astroos/branding/assetgen.py, shipped by this package) instead of the
#     upstream CachyOS screenshots
img=/usr/share/astroos/calamares/images
[[ -f $m/packagechooser_bootloader.conf ]] && sed -i -E \
  "s|screenshot: \"/etc/calamares/images/bootloaders/([a-z0-9-]+)\.[a-z]+\"|screenshot: \"$img/bootloaders/\1.png\"|" \
  "$m/packagechooser_bootloader.conf"
if [[ -f $m/packagechooser_desktop.conf ]]; then
  sed -i -E "s|screenshot: \"/etc/calamares/images/([a-z0-9-]+)\.[a-z]+\"|screenshot: \"$img/desktops/\1.png\"|" \
    "$m/packagechooser_desktop.conf"
  sed -i "s|$img/desktops/kde.png|$img/desktops/plasma.png|" "$m/packagechooser_desktop.conf"
fi

# 4. pacstrap: the same package map as netinstall.yaml over basePackages (the
#    CachyOS identity packages become ours, the CachyOS plymouth themes go),
#    then the AstroOS identity packages into the target root
p=$m/pacstrap.conf
if [[ -f $p ]]; then
  _map_pkgs "$p"
  # astroos-keyring already arrives from cachyos-keyring in the map above.
  # astroos-theme goes in beside them because it owns the plymouth theme
  # plymouthcfg.conf names: a target without it boots to a theme that is not
  # installed, and plymouth is left configured for a missing directory.
  grep -q '^\s*- astroos-branding\s*$' "$p" \
    || sed -i 's/^\(\s*\)- plymouth\s*$/&\n\1- astroos-branding\n\1- astroos-theme\n\1- astroos-tools/' "$p"
fi
# the target's first in-chroot pacman run needs every Include'd mirrorlist.
# Upstream copies the three CachyOS mirrorlists, which do not exist on an
# AstroOS live system: an unprefixed cp of a missing file fails the shellprocess
# step and aborts the install. astroos-{,v3-,v4-}mirrorlist ship the AstroOS
# ones and container-build.sh puts all three on the ISO, so a plain cp is right;
# blackarch-mirrorlist keeps its "-" because that repo is an ISO build flag.
i=$m/shellprocess_initialize_pacman.conf
if [[ -f $i ]]; then
  sed -i \
    -e 's|/etc/pacman.d/cachyos-mirrorlist|/etc/pacman.d/astroos-mirrorlist|g' \
    -e 's|/etc/pacman.d/cachyos-v3-mirrorlist|/etc/pacman.d/astroos-v3-mirrorlist|g' \
    -e 's|/etc/pacman.d/cachyos-v4-mirrorlist|/etc/pacman.d/astroos-v4-mirrorlist|g' \
    "$i"
  grep -q blackarch-mirrorlist "$i" \
    || sed -i 's|^\( - "cp /etc/pacman.d/astroos-v4-mirrorlist ${ROOT}/etc/pacman.d/"\)|\1\n - "-cp /etc/pacman.d/blackarch-mirrorlist ${ROOT}/etc/pacman.d/"|' "$i"
  grep -q cachyos "$i" && warn "a cachyos path survives in shellprocess_initialize_pacman.conf"
fi

# 5. scripts copied into the target and the installer's Python modules
[[ -f $s/bootloader-post-setup ]]        && sed -i \
  -e 's/TARGET_OS_NAME="CachyOS"/TARGET_OS_NAME="AstroOS"/' \
  -e '/^\s*pacman -S --noconfirm --needed cachyos-snapper-support\s*$/d' "$s/bootloader-post-setup"
[[ -f $s/btrfs-installation-snapshot ]]  && sed -i \
  -e 's/"Fresh CachyOS Installation"/"Fresh AstroOS Installation"/' \
  -e 's|/etc/cachyos|/etc/astroos|g' "$s/btrfs-installation-snapshot"
# these two run first in shellprocess@initialize_pacman, on the live system.
# update-mirrorlist ends in `sudo cachyos-rate-mirrors`, which on AstroOS is
# not a command at all: the step fails and the install aborts before it reaches
# the mirrorlist copies above. astroos-rate-mirrors ships /usr/bin/astroos-rate-mirrors.
[[ -f $s/update-mirrorlist ]] && sed -i 's/cachyos-rate-mirrors/astroos-rate-mirrors/g' "$s/update-mirrorlist"
# create-pacman-keyring pulls the distro keyring before archlinux-keyring; its
# `pacman-key --populate` takes no keyring argument, so it populates every
# keyring present, astroos.gpg included, and needs no change.
[[ -f $s/create-pacman-keyring ]] && sed -i \
  -e 's/cachyos-keyring/astroos-keyring/g' \
  -e 's|^# Update astroos-keyring first since archlinux-keyring is taken from cachyos$|# Update astroos-keyring first so the live system trusts the [astroos]|' \
  "$s/create-pacman-keyring"
# Limine has no theme file: the module writes the menu's colours straight into
# the target's limine.conf, so the AstroOS palette has to replace the
# Catppuccin one there, value by value. The eight-colour lines are exactly what
# `python3 astroos/branding/palette.py` prints, and both foregrounds become
# text, matching upstream's choice of one foreground for both.
#
# The two background lines keep upstream's ffffffff. Limine documents
# term_background as TTRRGGBB, transparency FIRST (CONFIG.md at v12.8.0, the
# version in Arch's limine package: "TT stands for transparency", default
# 00000000, or 80000000 when a wallpaper is displayed), and its parser reads
# term_background_bright the same unmasked way (common/lib/gterm.c). ffffffff
# is therefore fully transparent, which is what lets the AstroOS splash this
# module sets as the wallpaper show through; a palette colour there would be an
# opaque block over it. There is no sed for those two lines, so no colour
# outside the palette is written into this file either.
#
# The author line goes with the colours: after the seds below, none of that
# theme's values remain, and a credit for colours we replaced would be wrong.
if [[ -f $py/bootloader/main.py ]]; then
  sed -i \
    -e 's|# CachyOS Limine theme|# AstroOS Limine theme|' \
    -e 's|# Author: diegons490 (https://github.com/diegons490/cachyos-limine-theme)|# Author: AstroOS palette (astroos/branding/palette.py)|' \
    -e 's|/+CachyOS|/+AstroOS|' \
    -e 's|term_palette: 1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4|term_palette: 1b1630;e0679a;2cb8ab;e2b46a;7c6bd0;c99cdc;4ac0da;c8c4de|' \
    -e 's|term_palette_bright: 585b70;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4|term_palette_bright: 6b6688;f08ab5;5fd6c9;f0cb8c;9c8ce6;e29ef0;62e2ec;e8e6f5|' \
    -e 's|term_foreground: cdd6f4|term_foreground: e8e6f5|' \
    -e 's|term_foreground_bright: cdd6f4|term_foreground_bright: e8e6f5|' \
    "$py/bootloader/main.py"
  grep -q 'term_palette: 1b1630;' "$py/bootloader/main.py" \
    || warn "the Limine menu palette is not the AstroOS one"
  grep -q 'term_palette_bright: 6b6688;' "$py/bootloader/main.py" \
    || warn "the bright Limine menu palette is not the AstroOS one"
  grep -q 'term_foreground: e8e6f5' "$py/bootloader/main.py" \
    || warn "the Limine menu foreground is not the AstroOS text colour"
  grep -q 'term_foreground_bright: e8e6f5' "$py/bootloader/main.py" \
    || warn "the bright Limine menu foreground is not the AstroOS text colour"
  grep -q 'diegons490' "$py/bootloader/main.py" \
    && warn "the replaced Limine theme is still credited in bootloader/main.py"
fi
# chwd: only the progress string is CachyOS. The module shells out to the
# `chwd` binary, which astroos-chwd still installs as /usr/bin/chwd, so the
# command lines stay as they are.
[[ -f $py/chwd/main.py ]]       && sed -i 's/Installing needed drivers for CachyOS\.\.\./Installing needed drivers for AstroOS.../' "$py/chwd/main.py"
# pacstrap: the kernels and the GRUB theme are appended in code, not in
# pacstrap.conf, so _pkgmap never sees them. The theme is swapped rather than
# dropped: astroos-grub-theme owns the theme.txt grubcfg.conf points GRUB_THEME
# at, and it only reaches the target if it is in this list beside grub.
if [[ -f $py/pacstrap/main.py ]]; then
  sed -i \
    -e 's/"grub", "grub-hook", "cachyos-grub-theme", "os-prober"/"grub", "grub-hook", "astroos-grub-theme", "os-prober"/' \
    -e 's/"linux-cachyos-deckify-headers"/"linux-astroos-headers"/g' \
    -e 's/"linux-cachyos-deckify-zfs"/"linux-astroos-zfs"/g' \
    -e 's/"linux-cachyos-deckify"/"linux-astroos"/g' \
    -e 's/"linux-cachyos-lts-headers"/"linux-astroos-lts-headers"/g' \
    -e 's/"linux-cachyos-lts-zfs"/"linux-astroos-lts-zfs"/g' \
    -e 's/"linux-cachyos-lts"/"linux-astroos-lts"/g' \
    -e 's/"linux-cachyos-headers"/"linux-astroos-headers"/g' \
    -e 's/"linux-cachyos-zfs"/"linux-astroos-zfs"/g' \
    -e 's/"linux-cachyos"/"linux-astroos"/g' \
    "$py/pacstrap/main.py"
  grep -q 'cachyos' "$py/pacstrap/main.py" && warn "a cachyos package name survives in pacstrap/main.py"
  grep -q '"astroos-grub-theme"' "$py/pacstrap/main.py" \
    || warn "astroos-grub-theme is not in the GRUB package set in pacstrap/main.py"
fi

# 6. report what survived (the forge audit turns these into hard failures)
[[ -f $y ]] && grep -q '^\s*- cachyos-hello\s*$' "$y" && warn "cachyos-hello survives in netinstall.yaml"
[[ -f $y ]] && ! grep -q '^- name: "AstroOS (hidden)"' "$y" && warn "AstroOS groups missing from netinstall.yaml"
[[ -f $p ]] && ! grep -q '^\s*- astroos-branding\s*$' "$p" && warn "astroos-branding not in pacstrap basePackages"
[[ -f $p ]] && ! grep -q '^\s*- astroos-keyring\s*$' "$p" && warn "astroos-keyring not in pacstrap basePackages"
[[ -f $p ]] && ! grep -q '^\s*- astroos-theme\s*$' "$p" && warn "astroos-theme not in pacstrap basePackages (the plymouth theme would be missing)"
[[ -f $p ]] && grep -qi cachy "$p" && warn "a cachyos package name survives in pacstrap.conf"
grep -q '^branding: astroos' /usr/share/calamares/settings_online.conf 2>/dev/null || warn "settings_online.conf does not select the astroos branding"
[[ -f $m/packagechooser_bootloader.conf ]] && ! grep -q "$img/bootloaders/limine.png" "$m/packagechooser_bootloader.conf" && warn "bootloader previews still upstream"
[[ -f $m/packagechooser_desktop.conf ]] && ! grep -q "$img/desktops/plasma.png" "$m/packagechooser_desktop.conf" && warn "desktop previews still upstream"
[[ -f $y ]] && grep -qi cachy "$y" && warn "CachyOS survives in netinstall.yaml"
exit 0
