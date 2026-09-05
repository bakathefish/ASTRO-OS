#!/usr/bin/env bash
# Re-points the CachyOS Calamares configuration at AstroOS. Runs as an alpm
# PostTransaction hook whenever cachyos-calamares-next (or astroos-calamares)
# is installed or upgraded, so the installer package itself is never forked:
# every edit is a targeted, idempotent sed on the upstream file, plus two
# whole-file replacements (netinstall.conf, plymouthcfg.conf) and one append
# (the AstroOS package groups). Survey: .planning/R4_BRANDING_SURVEY.md §0/§2.
# Exit status is always 0 (a hook failure would abort every pacman run); a
# surviving CachyOS surface is reported as a WARNING line for the build log,
# and the forge audit asserts the result inside the ISO.
set -u
d=/usr/share/astroos/calamares
m=/etc/calamares/modules
s=/etc/calamares/scripts
py=/usr/lib/calamares/modules
[[ -d $m ]] || exit 0

# 1. branding component: ours ships beside upstream's; the settings select it
for f in /usr/share/calamares/settings.conf /usr/share/calamares/settings_online.conf /usr/share/calamares/settings_offline.conf; do
  [[ -f $f ]] && sed -i 's/^branding:.*/branding: astroos/' "$f"
done

# 2. package lists. netinstall.conf: local groups file ONLY (upstream lists a
#    GitHub URL first, which would let the installed set change after the ISO
#    ships). netinstall.yaml: CachyOS-only apps and themes out, capitalised
#    brand in group titles, AstroOS groups appended (generated from
#    astroos/meta at package build time).
install -m644 "$d/netinstall.conf" "$m/netinstall.conf"
y=$m/netinstall.yaml
if [[ -f $y ]]; then
  for p in cachyos-hello cachyos-packageinstaller cachyos-wallpapers \
           cachyos-emerald-kde-theme-git cachyos-iridescent-kde cachyos-nord-kde-theme-git; do
    sed -i "/^\s*- ${p}\s*$/d" "$y"
  done
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
[[ -f $m/bootloader.conf ]] && sed -i \
  -e 's/^efiBootloaderId:.*/efiBootloaderId: "astroos"/' \
  -e 's|^limineSplashLogo:.*|limineSplashLogo: "/usr/share/astroos/branding/limine-splash.png"|' "$m/bootloader.conf"
if [[ -f $m/grubcfg.conf ]]; then
  # no CachyOS GRUB theme; the AstroOS splash behind GRUB's own menu instead
  sed -i '/^\s*GRUB_THEME:/d' "$m/grubcfg.conf"
  grep -q '^\s*GRUB_BACKGROUND:' "$m/grubcfg.conf" \
    || sed -i 's|^\(\s*\)GRUB_TOP_LEVEL:.*|&\n\1GRUB_BACKGROUND: "/usr/share/astroos/branding/limine-splash.png"|' "$m/grubcfg.conf"
fi
install -m644 "$d/plymouthcfg.conf" "$m/plymouthcfg.conf"
[[ -f $m/welcome_online.conf ]] && sed -i 's|^\(\s*internetCheckUrl:\s*\).*|\1https://archlinux.org|' "$m/welcome_online.conf"

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

# 4. pacstrap: AstroOS identity packages into the target root, the CachyOS
#    plymouth themes out (the spinner theme + AstroOS watermark replace them)
p=$m/pacstrap.conf
if [[ -f $p ]]; then
  sed -i -e '/^\s*- cachyos-plymouth-bootanimation\s*$/d' -e '/^\s*- cachyos-plymouth-theme\s*$/d' "$p"
  grep -q '^\s*- astroos-branding\s*$' "$p" \
    || sed -i 's/^\(\s*\)- plymouth\s*$/&\n\1- astroos-keyring\n\1- astroos-branding\n\1- astroos-tools/' "$p"
fi
# the target's first in-chroot pacman run needs every Include'd mirrorlist
i=$m/shellprocess_initialize_pacman.conf
if [[ -f $i ]] && ! grep -q blackarch-mirrorlist "$i"; then
  sed -i 's|^\( - "cp /etc/pacman.d/cachyos-v4-mirrorlist ${ROOT}/etc/pacman.d/"\)|\1\n - "-cp /etc/pacman.d/blackarch-mirrorlist ${ROOT}/etc/pacman.d/"|' "$i"
fi

# 5. scripts copied into the target and the installer's Python modules
[[ -f $s/bootloader-post-setup ]]        && sed -i 's/TARGET_OS_NAME="CachyOS"/TARGET_OS_NAME="AstroOS"/' "$s/bootloader-post-setup"
[[ -f $s/btrfs-installation-snapshot ]]  && sed -i 's/"Fresh CachyOS Installation"/"Fresh AstroOS Installation"/' "$s/btrfs-installation-snapshot"
[[ -f $py/bootloader/main.py ]] && sed -i -e 's|# CachyOS Limine theme|# AstroOS Limine theme|' -e 's|/+CachyOS|/+AstroOS|' "$py/bootloader/main.py"
[[ -f $py/chwd/main.py ]]       && sed -i 's/Installing needed drivers for CachyOS\.\.\./Installing needed drivers for AstroOS.../' "$py/chwd/main.py"
[[ -f $py/pacstrap/main.py ]]   && sed -i 's/"grub", "grub-hook", "cachyos-grub-theme", "os-prober"/"grub", "grub-hook", "os-prober"/' "$py/pacstrap/main.py"

# 6. report what survived (the forge audit turns these into hard failures)
warn() { echo "astroos-calamares: WARNING: $1" >&2; }
[[ -f $y ]] && grep -q '^\s*- cachyos-hello\s*$' "$y" && warn "cachyos-hello survives in netinstall.yaml"
[[ -f $y ]] && ! grep -q '^- name: "AstroOS (hidden)"' "$y" && warn "AstroOS groups missing from netinstall.yaml"
[[ -f $p ]] && ! grep -q '^\s*- astroos-branding\s*$' "$p" && warn "astroos-branding not in pacstrap basePackages"
grep -q '^branding: astroos' /usr/share/calamares/settings_online.conf 2>/dev/null || warn "settings_online.conf does not select the astroos branding"
[[ -f $m/packagechooser_bootloader.conf ]] && ! grep -q "$img/bootloaders/limine.png" "$m/packagechooser_bootloader.conf" && warn "bootloader previews still upstream"
[[ -f $m/packagechooser_desktop.conf ]] && ! grep -q "$img/desktops/plasma.png" "$m/packagechooser_desktop.conf" && warn "desktop previews still upstream"
[[ -f $y ]] && grep -q 'CachyOS' "$y" && warn "CachyOS survives in netinstall.yaml"
exit 0
