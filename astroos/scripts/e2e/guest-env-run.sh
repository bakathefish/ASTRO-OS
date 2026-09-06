#!/usr/bin/env bash
# Run a command inside the guest with the complete environment of the running
# Plasma session (over ssh, as the session's user), the way a launcher started
# from the desktop would inherit it. guest-launch.sh exports a fixed subset
# (display, bus, runtime dir), which is enough to put a window on screen but
# not enough to reproduce what a user sees: without XDG_CONFIG_DIRS the
# kdedefaults layer is invisible, so System Settings highlighted "Breeze
# Light" for a session that was plainly AstroOS Dark (2026-09-06), and
# plasma-apply-colorscheme aborted for want of a platform. Every variable of
# plasmashell's environ is exported here, the given command is exec'd in it.
#   guest-env-run.sh <command> [args...]
set -u
pid=$(pgrep -u "$USER" -x plasmashell | head -1)
[[ -n $pid ]] || { echo "no plasmashell for $USER" >&2; exit 1; }
while IFS= read -r -d '' kv; do
  case $kv in
    _=*|SHLVL=*|PWD=*|OLDPWD=*) ;;
    *=*) export "$kv" ;;
  esac
done < "/proc/$pid/environ"
exec "$@"
