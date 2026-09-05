#!/usr/bin/env bash
# Run inside the LIVE guest as liveuser (over ssh): start the AstroOS installer
# launcher with the environment of the running Plasma session, so its output
# lands in /tmp/launch.log instead of vanishing behind a GUI click. Also the
# first assertion of the end-to-end test: the installer binary must have no
# missing shared libraries (the 2026-09-05 boost 1.91/1.92 mismatch).
# The session locale (LANG=C.UTF-8 in the live session) is carried over on
# purpose: pkexec keeps LANG, and Calamares's embedded Python decodes
# pacstrap's output with it. An ssh session has no LANG, and without it the
# first non-ASCII byte of pacman output kills the pacstrap job
# (UnicodeDecodeError, observed 2026-09-05).
set -u
if ldd /usr/bin/calamares | grep -q "not found"; then
  echo "FAIL calamares has missing libraries:"; ldd /usr/bin/calamares | grep "not found"
  exit 2
fi
echo "PASS calamares links cleanly"
pid=$(pgrep -u "$USER" -x plasmashell | head -1)
[[ -n $pid ]] || { echo "no plasmashell for $USER"; exit 1; }
while IFS= read -r -d '' kv; do
  case $kv in
    WAYLAND_DISPLAY=*|DISPLAY=*|XDG_RUNTIME_DIR=*|DBUS_SESSION_BUS_ADDRESS=*|XAUTHORITY=*|XDG_SESSION_TYPE=*|XDG_CURRENT_DESKTOP=*|XDG_SESSION_ID=*|XDG_SEAT=*|XDG_VTNR=*|LANG=*|LANGUAGE=*|LC_*=*)
      # shellcheck disable=SC2163  # exporting the NAME=value pair itself is intended
      export "$kv" ;;
  esac
done < "/proc/$pid/environ"
echo "session env: WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-} DISPLAY=${DISPLAY:-} XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-} LANG=${LANG:-}"
nohup /usr/local/bin/calamares-online.sh > /tmp/launch.log 2>&1 < /dev/null &
echo "launcher pid $!"
sleep 25
echo "== /tmp/launch.log =="; cat /tmp/launch.log
echo "== ~/astroos-install.log (tail) =="; tail -15 ~/astroos-install.log 2>/dev/null || echo "(no install log yet)"
echo "== calamares processes =="; pgrep -a calamares || echo "(none)"
