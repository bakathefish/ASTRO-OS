#!/bin/bash
# AstroOS live installer launcher. Replaces the CachyOS-Live-ISO copy (same
# path, unowned): identical keyring refresh, but the installer package is NOT
# re-downloaded at launch (the ISO ships the tested cachyos-calamares-next and
# the astroos-calamares hook has already re-pointed its configuration), and
# the AstroOS + BlackArch keyrings are populated alongside Arch and CachyOS.
# Launched by plasma-welcome's Install button and the "Install AstroOS" menu
# entry (usr/share/applications/astroos-install.desktop).

main() {
    # Recreate the keyring first: Arch re-signs archlinux-keyring often enough
    # that a stale live keyring fails the installation (upstream rationale).
    sudo rm -rf /etc/pacman.d/gnupg
    sudo pacman -Sy --noconfirm archlinux-keyring cachyos-keyring
    sudo pacman-key --init
    local kr=(archlinux cachyos)
    [ -f /usr/share/pacman/keyrings/astroos.gpg ] && kr+=(astroos)
    [ -f /usr/share/pacman/keyrings/blackarch.gpg ] && kr+=(blackarch)
    sudo pacman-key --populate "${kr[@]}"
    # a clock in the past makes freshly created keys "from the future"
    timedatectl set-ntp true

    local progname
    progname="$(basename "$0")"
    local log="/home/liveuser/astroos-install.log"
    local mode="online"

    local SYSTEM=""
    if [ -d /sys/firmware/efi ]; then
        SYSTEM="UEFI SYSTEM"
    else
        SYSTEM="BIOS/MBR SYSTEM"
    fi

    local ISO_VERSION
    ISO_VERSION="$(cat /etc/version-tag 2>/dev/null || echo unknown)"
    echo "USING ISO VERSION: ${ISO_VERSION}"

    # Hardware information for the log
    inxi -F > "$log" 2>/dev/null || true

    cat <<EOF >> "$log"
########## $log by $progname
########## Started (UTC): $(date -u "+%x %X")
########## ISO version: $ISO_VERSION
########## System: $SYSTEM
EOF

    sudo cp "/usr/share/calamares/settings_${mode}.conf" /etc/calamares/settings.conf
    exec pkexec-wrapper calamares -D6 >> "$log"
}

main "$@"
