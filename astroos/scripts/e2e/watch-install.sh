#!/usr/bin/env bash
# Poll the Calamares install running inside the guest (over the ssh port
# forward set up per README.md) until its last job starts, calamares exits,
# or the cap expires. One line per poll: state, last job, error count, target
# disk usage.
#   watch-install.sh [ssh-port (2222)] [cap-minutes (110)]
set -u
port="${1:-2222}"
cap=$(( ${2:-110} * 60 ))
t0=$(date +%s)
g() { ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 liveuser@127.0.0.1 "$@" 2>/dev/null; }
while :; do
  now=$(date +%s)
  if (( now - t0 > cap )); then echo "CAP reached"; exit 1; fi
  out=$(g 'pgrep -x calamares >/dev/null && echo RUNNING || echo GONE; grep -E "Starting job" ~/astroos-install.log | tail -1 | sed -E "s/^ +//"; grep -ciE "job failed|installation failed" ~/astroos-install.log; df -h --output=used,avail /tmp/calamares-root-*/ 2>/dev/null | sed -n 2p' | tr '\n' ' ')
  echo "[$(date -u +%H:%M:%S)] $out"
  case "$out" in
    *GONE*) echo "calamares exited"; exit 0 ;;
    *"( 47 / 47 )"*) echo "last job started"; exit 0 ;;
  esac
  sleep 120
done
