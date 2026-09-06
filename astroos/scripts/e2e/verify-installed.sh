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
# a check whose subject is not installed here says so; it never counts as a pass
skip() { printf 'SKIP %s\n' "$1"; }
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
chk "no CachyOS in motd/issue/lsb-release" bash -c '! grep -qi cachyos /etc/motd /etc/issue /etc/lsb-release'
chk "hostname is $want_host"          bash -c "[[ \$(hostname) == '$want_host' ]]"
chk "fastfetch reports AstroOS"       bash -c 'fastfetch --logo none 2>/dev/null | grep -q "OS: AstroOS"'
chk "bash greeting in ~/.bashrc"      grep -q 'AstroOS terminal greeting' "$HOME/.bashrc"
chk "fish greeting drop-in present"   test -f "$HOME/.config/fish/conf.d/astroos-greeting.fish"
chk "plymouth watermark present"      test -f /usr/share/astroos/branding/watermark.png
chk "greeter background installed"    test -f /usr/share/astroos/branding/login-background.png
chk "AstroOS wallpaper installed"     test -f /usr/share/wallpapers/AstroOS/contents/images/3840x2160.png
chk "Kickoff icon is astroos-logo"    grep -q '^icon=astroos-logo' "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
chk "SDDM greeter background is AstroOS" grep -q '^background=/usr/share/astroos/branding/login-background.png' /usr/share/sddm/themes/breeze/theme.conf.user
chk "plasmalogin greeter wallpaper drop-in" grep -q '^Image=/usr/share/astroos/branding/login-background.png' /usr/lib/plasmalogin/plasmalogin.conf.d/10-astroos-wallpaper.conf
chk "no /etc/cachyos-release"          bash -c '[[ ! -e /etc/cachyos-release ]]'
chk "no CachyOS icon file"             bash -c '[[ ! -e /usr/share/icons/cachyos.svg ]]'
chk "scalable astroos-logo.svg"        test -f /usr/share/icons/hicolor/scalable/apps/astroos-logo.svg
chk "GNOME login logo override"        grep -q 'astroos-logo.svg' /usr/share/glib-2.0/schemas/zz_astroos.org.gnome.login-screen.gschema.override
chk "rEFInd OS icon shipped"           test -f /usr/share/refind/icons/os_astroos.png
# prose we ship and the owner reads; only the laptop profile puts anything here
if [[ -d /usr/share/doc/astroos ]]; then
  chk "no CachyOS in the shipped AstroOS docs" bash -c '! grep -rqi cachyos /usr/share/doc/astroos'
else
  skip "no CachyOS in the shipped AstroOS docs (astroos-zenbook-duo not installed)"
fi

echo "== repositories and trust"
chk "[astroos] in pacman.conf"        grep -q '^\[astroos\]' /etc/pacman.conf
chk "[astroos] after [extra]"         bash -c 'a=$(grep -n "^\[extra\]" /etc/pacman.conf | cut -d: -f1); b=$(grep -n "^\[astroos\]" /etc/pacman.conf | cut -d: -f1); [[ -n $a && -n $b && $b -gt $a ]]'
chk "[blackarch] in pacman.conf"      grep -q '^\[blackarch\]' /etc/pacman.conf
chk "[blackarch] after [astroos]"     bash -c 'a=$(grep -n "^\[astroos\]" /etc/pacman.conf | cut -d: -f1); b=$(grep -n "^\[blackarch\]" /etc/pacman.conf | cut -d: -f1); [[ -n $a && -n $b && $b -gt $a ]]'
chk "astroos key in the keyring"      bash -c 'sudo_ pacman-key --list-keys 2>/dev/null | grep -q DA5C947A5C329E528948830E92304756ECC2F9D8'
chk "astroos key locally signed"      bash -c 'sudo_ pacman-key --list-sigs DA5C947A5C329E528948830E92304756ECC2F9D8 2>/dev/null | grep -qi "pacman keyring master key"'
chk "pacman -Sy works with SigLevel"  sudo_ pacman -Sy
chk "[astroos] package signature verifies (pacman -Sw)" sudo_ pacman -Sw --noconfirm python-fleep
# independence from CachyOS: [astroos] carries the rebuilt packages, so no
# repository whose name starts with "cachy" may be configured any more, not in
# pacman.conf and not in anything it Includes
echo "     repositories: $(pacman-conf --repo-list 2>/dev/null | tr '\n' ' ')"
chk "pacman-conf lists astroos"       bash -c 'pacman-conf --repo-list | grep -qx astroos'
chk "pacman-conf lists no cachy* repo" bash -c '! pacman-conf --repo-list | grep -qE "^cachy"'
chk "no mirror.cachyos.org in pacman.conf" bash -c '! grep -q "mirror\.cachyos\.org" /etc/pacman.conf'
chk "astroos-mirrorlist installed"    test -f /etc/pacman.d/astroos-mirrorlist
chk "no cachyos-mirrorlist"           bash -c '[[ ! -e /etc/pacman.d/cachyos-mirrorlist ]]'

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
# the headline independence check: an installed AstroOS system carries zero
# CachyOS-named packages. The offending names are the whole diagnosis when
# this regresses, so print them.
cachy_pkgs=$(pacman -Qq 2>/dev/null | grep -E '^cachy' | tr '\n' ' ')
chk "zero cachy* packages installed"  bash -c '! pacman -Qq 2>/dev/null | grep -qE "^cachy"'
[[ -z $cachy_pkgs ]] || echo "     cachy-named packages still installed: $cachy_pkgs"

echo "== kernel"
echo "     uname -r: $(uname -r)"
# Two flavours ship, and they must carry different localversion suffixes or
# their module trees would collide: the main kernel ends -astroos, the LTS one
# ends -astroos-lts. Match both, so booting LTS does not fail a passing system.
chk "kernel release carries -astroos" bash -c '[[ $(uname -r) == *-astroos || $(uname -r) == *-astroos-lts ]]'
chk "kernel release has no cachyos"   bash -c '[[ $(uname -r) != *cachyos* ]]'
# a rename that drops the localversion suffix leaves the modules in a directory
# the running kernel never looks in, and every module silently disappears;
# catch that here rather than on the owner's machine
chk "module tree for the running kernel" bash -c '[[ -d /usr/lib/modules/$(uname -r) ]]'
chk "module tree has kernel/"         bash -c '[[ -d /usr/lib/modules/$(uname -r)/kernel ]]'
# the kernel package is ours, and the copy on disk is the one [astroos]
# publishes. pacman -Qi carries no repository field for an installed package,
# so prove the origin by matching the installed version against the repo's.
# Packager is printed for the reader only: the build container leaves PACKAGER
# unset, so [astroos] packages read "Unknown Packager" until
# astroos/scripts/build-aur-repo.sh sets it.
astroos_owns_kernel() {
  local repo_ver local_ver
  repo_ver=$(pacman -Sl astroos 2>/dev/null | awk '$2 == "linux-astroos" { print $3 }')
  local_ver=$(pacman -Q linux-astroos 2>/dev/null | awk '{ print $2 }')
  [[ -n $repo_ver && $repo_ver == "$local_ver" ]]
}
echo "     linux-astroos packager: $(pacman -Qi linux-astroos 2>/dev/null | sed -n 's/^Packager *: *//p')"
chk "kernel package is linux-astroos" pacman -Qq linux-astroos
chk "[astroos] provides the installed linux-astroos" astroos_owns_kernel
chk "linux-astroos packager is not CachyOS" bash -c '! pacman -Qi linux-astroos 2>/dev/null | sed -n "s/^Packager *: *//p" | grep -qi cachy'

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
