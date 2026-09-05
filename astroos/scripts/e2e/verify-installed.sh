#!/usr/bin/env bash
# Assert the AstroOS identity and wiring on an INSTALLED system. Run inside the
# guest, as the installed user, over ssh, after the first boot of the installed
# disk (README.md). Prints PASS/FAIL per check, exits non-zero if any failed.
#   E2E_PASS      the user's password, for sudo (the harness user, never a real one)
#   E2E_HOSTNAME  hostname typed into the installer (default astroos-e2e)
set -u
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }
chk()  { local name=$1; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else bad "$name"; fi; }
# password on stdin every time: without a tty, sudo's cached ticket does not
# carry into subshells, so a plain `sudo` inside $(...) or `bash -c` prompts
# and fails silently
sudo_() { printf '%s\n' "${E2E_PASS:-}" | sudo -S -p '' "$@" 2>/dev/null; }
export E2E_PASS; export -f sudo_
want_host="${E2E_HOSTNAME:-astroos-e2e}"

echo "== identity"
chk "os-release NAME=AstroOS"         grep -qx 'NAME="AstroOS"' /etc/os-release
chk "os-release ID=arch (kept on purpose)" grep -qx 'ID=arch' /etc/os-release
chk "os-release has no CachyOS"        bash -c '! grep -qi cachyos /etc/os-release'
chk "os-release LOGO=astroos-logo"    grep -qx 'LOGO=astroos-logo' /etc/os-release
chk "lsb-release names AstroOS"       grep -q 'AstroOS' /etc/lsb-release
chk "issue names AstroOS"             grep -q 'AstroOS' /etc/issue
chk "motd welcomes to AstroOS"        grep -q 'Welcome to AstroOS' /etc/motd
chk "motd has no CachyOS welcome"     bash -c '! grep -qi "welcome to your.*cachyos" /etc/motd'
chk "hostname is $want_host"          bash -c "[[ \$(hostname) == '$want_host' ]]"
chk "fastfetch reports AstroOS"       bash -c 'fastfetch --logo none 2>/dev/null | grep -q "OS: AstroOS"'
chk "bash greeting in ~/.bashrc"      grep -q 'AstroOS terminal greeting' "$HOME/.bashrc"
chk "fish greeting drop-in present"   test -f "$HOME/.config/fish/conf.d/astroos-greeting.fish"
chk "plymouth watermark present"      test -f /usr/share/astroos/branding/watermark.png
chk "AstroOS wallpaper installed"     test -f /usr/share/wallpapers/AstroOS/contents/images/3840x2160.png
chk "Kickoff icon is astroos-logo"    grep -q '^icon=astroos-logo' "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
chk "SDDM greeter background is AstroOS" grep -q '^background=/usr/share/wallpapers/AstroOS/' /usr/share/sddm/themes/breeze/theme.conf.user
chk "plasmalogin greeter wallpaper drop-in" grep -q '^Image=/usr/share/wallpapers/AstroOS/' /usr/lib/plasmalogin/plasmalogin.conf.d/10-astroos-wallpaper.conf
chk "no /etc/cachyos-release"          bash -c '[[ ! -e /etc/cachyos-release ]]'
chk "no CachyOS icon file"             bash -c '[[ ! -e /usr/share/icons/cachyos.svg ]]'
chk "scalable astroos-logo.svg"        test -f /usr/share/icons/hicolor/scalable/apps/astroos-logo.svg
chk "GNOME login logo override"        grep -q 'astroos-logo.svg' /usr/share/glib-2.0/schemas/zz_astroos.org.gnome.login-screen.gschema.override
chk "rEFInd OS icon shipped"           test -f /usr/share/refind/icons/os_astroos.png

echo "== repositories and trust"
chk "[astroos] in pacman.conf"        grep -q '^\[astroos\]' /etc/pacman.conf
chk "[astroos] after [extra]"         bash -c 'a=$(grep -n "^\[extra\]" /etc/pacman.conf | cut -d: -f1); b=$(grep -n "^\[astroos\]" /etc/pacman.conf | cut -d: -f1); [[ -n $a && -n $b && $b -gt $a ]]'
chk "[blackarch] in pacman.conf"      grep -q '^\[blackarch\]' /etc/pacman.conf
chk "[blackarch] after [astroos]"     bash -c 'a=$(grep -n "^\[astroos\]" /etc/pacman.conf | cut -d: -f1); b=$(grep -n "^\[blackarch\]" /etc/pacman.conf | cut -d: -f1); [[ -n $a && -n $b && $b -gt $a ]]'
chk "astroos key in the keyring"      bash -c 'sudo_ pacman-key --list-keys 2>/dev/null | grep -q DA5C947A5C329E528948830E92304756ECC2F9D8'
chk "astroos key locally signed"      bash -c 'sudo_ pacman-key --list-sigs DA5C947A5C329E528948830E92304756ECC2F9D8 2>/dev/null | grep -qi "pacman keyring master key"'
chk "pacman -Sy works with SigLevel"  sudo_ pacman -Sy
chk "[astroos] package signature verifies (pacman -Sw)" sudo_ pacman -Sw --noconfirm python-fleep

echo "== packages"
for p in astroos-keyring astroos-branding astroos-tools astroos-zenbook-duo; do
  chk "installed: $p" pacman -Qq "$p"
done
chk "astroos-branding owns the SDDM greeter config" bash -c '[[ $(pacman -Qqo /usr/share/sddm/themes/breeze/theme.conf.user 2>/dev/null) == astroos-branding ]]'
chk "installer-only shim absent"      bash -c '! pacman -Qq astroos-calamares-boost-compat'
chk "installer component absent"      bash -c '! pacman -Qq astroos-calamares'
chk "cachyos-hello absent"            bash -c '! pacman -Qq cachyos-hello'
for p in siril-git python-healpy astromatic-swarp; do
  chk "[astroos] sample installed: $p" pacman -Qq "$p"
done
chk "a [blackarch] package installed" bash -c 'pacman -Qq nmap >/dev/null || pacman -Qq sqlmap >/dev/null || pacman -Qq aircrack-ng >/dev/null'

echo "== hooks"
for h in zz-astroos-identity.hook 85-astroos-plymouth-watermark.hook 86-astroos-skel.hook astroos-reboot-required.hook; do
  chk "hook present: $h" test -f "/etc/pacman.d/hooks/$h"
done
for h in cachyos-branding.hook lsb-release.hook os-release.hook cachyos-reboot-required.hook; do
  chk "cachyos hook masked: $h" bash -c "[[ \$(readlink /etc/pacman.d/hooks/$h) == /dev/null ]]"
done

echo "== services"
chk "graphical.target active"         systemctl is-active graphical.target
chk "display manager enabled"         bash -c 'systemctl is-enabled sddm.service || systemctl is-enabled plasmalogin.service'
echo "     display manager: $(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)")"
chk "no failed units"                 bash -c '[[ $(systemctl --failed --no-legend | wc -l) -eq 0 ]]'
chk "network online"                  systemctl is-active network-online.target
chk "zenbook-duo inert here"          bash -c '! astroos-is-duo'
chk "zenbook-duo units installed"     bash -c 'ls /usr/lib/systemd/system/zenbook-duo*.service | grep -q .'
chk "astroos-doctor --quick"          astroos-doctor --quick

echo
if (( fail == 0 )); then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit $fail
