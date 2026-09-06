#!/usr/bin/env bash
# AstroOS live installer launcher. Replaces the CachyOS-Live-ISO copy (same
# path, unowned): identical keyring refresh, but the installer package is NOT
# re-downloaded at launch (the ISO ships the tested astroos-calamares-installer
# build and the astroos-calamares hook has already re-pointed its
# configuration; only astroos-calamares itself is refreshed from [astroos],
# which re-runs that hook), and the keyrings populated are AstroOS's own plus
# Arch, and BlackArch when the ISO carries it.
# Launched by plasma-welcome's Install button and the "Install AstroOS" menu
# entry (usr/share/applications/astroos-install.desktop).

main() {
    # Recreate the keyring first: Arch re-signs archlinux-keyring often enough
    # that a stale live keyring fails the installation (upstream rationale).
    sudo rm -rf /etc/pacman.d/gnupg
    sudo pacman -Sy --noconfirm archlinux-keyring astroos-keyring
    sudo pacman-key --init
    # pacman-key rejects the WHOLE populate call when one named keyring file
    # is missing, which would cost us the Arch keys too, so name only the ones
    # that are there: astroos.gpg ships with astroos-keyring and is always
    # present, blackarch.gpg only on a BlackArch build.
    local kr=(archlinux)
    [ -f /usr/share/pacman/keyrings/astroos.gpg ] && kr+=(astroos)
    [ -f /usr/share/pacman/keyrings/blackarch.gpg ] && kr+=(blackarch)
    sudo pacman-key --populate "${kr[@]}"
    # the installer configuration and branding are a repo package: refresh it
    # so fixes published after this ISO reach the installer (the online
    # install needs the network anyway; a miss here is not fatal)
    sudo pacman -S --noconfirm --needed astroos-calamares || echo "astroos-calamares refresh skipped"
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

    # Calamares embeds Python and decodes pacstrap's output with the process
    # locale (pkexec keeps LANG). The Plasma session sets LANG=C.UTF-8; a bare
    # tty or ssh launch does not, and then the first non-ASCII byte of pacman
    # output fails the pacstrap job with a UnicodeDecodeError.
    case "${LC_ALL:-${LANG:-}}" in
        *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
        *) export LANG=C.UTF-8; unset LC_ALL ;;
    esac

    sudo cp "/usr/share/calamares/settings_${mode}.conf" /etc/calamares/settings.conf
    exec pkexec-wrapper calamares -D6 >> "$log"
}

main "$@"
