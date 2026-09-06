#!/usr/bin/env bash
# AstroOS bug reporting shell script.  This shell
# script will generate a log file named "astroos-bugreport.log".

set -euo pipefail

LOG_FILENAME="${LOG_FILENAME:-"astroos-bugreport.log"}"
OLD_LOG_FILENAME=astroos-bugreport.log.old

check_root(){
    # Check that we are root, required for dmesg
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: Please run $(basename "$0") as root." >&2
        exit 1
    fi
}


# move any old log file
check_oldlog() {
    if [ -f "$LOG_FILENAME" ]; then
        mv "$LOG_FILENAME" "$OLD_LOG_FILENAME"
    fi
}


check_wpermission() {
    if ! touch "$LOG_FILENAME" 2>/dev/null; then
        cat << EOF >&2

ERROR: Working directory is not writable; please cd to a directory
       where you have write permission so that the $LOG_FILENAME
       file can be written.

EOF
        exit 1
    fi
}

get_installed_packages() {
    local repo found=0
    # list from every [astroos*] repo that is actually configured, most
    # specific architecture tier first. astroos-v3 and astroos-v4 are the tiers
    # the mirrorlist packages reserve; only [astroos] has a Server line today.
    for repo in astroos-v4 astroos-v3 astroos; do
        if [ -e "/var/lib/pacman/sync/${repo}.db" ]; then
            pacman -Ss | grep --color=never "^${repo}/.*\[installed\]" || true
            found=1
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo "No AstroOS repository is configured"
    fi
}

bugreport() {
    echo "Starting with bugreport"

    cat << EOF >"$LOG_FILENAME"
____________________________________________

Start of AstroOS bug report log file. Please send this report,
along with a description of your bug, to AstroOS.

Date: $(date)
uname: $(uname -a)
cmdline: $(cat /proc/cmdline)

____________________________________________
Getting Hardware Information

$(inxi -Farz)
____________________________________________
Getting Scheduler information

sched-ext:
$(grep -R "" /sys/kernel/sched_ext/ 2>/dev/null || echo "sched_ext not available")

$(journalctl --output cat -k | grep -i scheduler || true)

____________________________________________

dmesg

$(dmesg)

____________________________________________
journalctl of current boot

$(journalctl -b -p 4..1)
____________________________________________
journalctl of previous boot

$(journalctl -b -1 -p 4..1 2>/dev/null || echo "No previous boot log available")
____________________________________________

Installed packages

$(get_installed_packages)
--------------------------------------------
EOF
}

redact() {
    echo "Redacting personal information..."

    local sed_args=()

    # Escape a literal string for use in a sed pattern (] must be first in class)
    sed_escape() { printf '%s\n' "$1" | sed 's/[][\\.^$*|]/\\&/g'; }

    # Redact hostname (appears in uname, dmesg, journalctl)
    local hn
    hn=$(hostname)
    sed_args+=(-e "s|$(sed_escape "$hn")|<hostname-redacted>|g")

    # Redact real username and home directory (SUDO_USER is set when run via sudo)
    local real_user="${SUDO_USER:-}"
    if [ -n "$real_user" ] && [ "$real_user" != "root" ]; then
        local escaped_user
        escaped_user=$(sed_escape "$real_user")
        sed_args+=(-e "s|/home/${escaped_user}|<home-dir-redacted>|g")
        sed_args+=(-e "s|${escaped_user}|<username-redacted>|g")
    fi

    # Redact IPv4 addresses (inxi -z handles its own output; this covers dmesg/journal)
    sed_args+=(-e 's/\b\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\b/<ipv4-redacted>/g')

    # Redact MAC addresses (fallback for anything inxi -z may have missed)
    sed_args+=(-e 's/\b\([0-9a-fA-F]\{2\}:\)\{5\}[0-9a-fA-F]\{2\}\b/<mac-address-redacted>/g')

    # Redact email addresses
    sed_args+=(-e 's/[a-zA-Z0-9._%+-]\+@[a-zA-Z0-9.-]\+\.[a-zA-Z]\{2,\}/<email-address-redacted>/g')

    # Single sed pass for all substitutions
    sed -i "${sed_args[@]}" "$LOG_FILENAME"
}

report_next_steps() {
    # AstroOS runs no paste service, so the log stays on the machine and the
    # user decides what to share. Upstream offered an upload to a distro-run
    # pastebin here; the redact() pass above is best effort, not a guarantee.
    echo
    echo "Log written to: $(readlink -f -- "$LOG_FILENAME")"
    echo "Read it over, then attach it to a new issue at"
    echo "https://github.com/bakathefish/ASTRO-OS/issues"
}

check_root
check_oldlog
check_wpermission
bugreport
redact
report_next_steps
