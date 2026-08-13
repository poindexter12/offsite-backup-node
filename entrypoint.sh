#!/bin/bash
# Supervisor for the single-image stack. Three processes, one lifecycle:
#   containerboot (tailscaled + serve)  — critical: death exits the container
#   rest-server                         — critical: death exits the container
#   alloy                               — best-effort: restarted in a loop,
#                                         telemetry loss must never take down
#                                         the backup target itself
# Docker's restart policy handles the critical exits.
set -u

prefix() { sed -u "s/^/[$1] /"; }

# --- bandwidth shaping (MAX_UP_MBIT / MAX_DOWN_MBIT, 0 = unlimited) ---------
# Same tc rules the old shaper sidecar applied; the container needs NET_ADMIN.
# Shaping failure is a warning, not fatal — an unshaped backup box still works.
shape() {
  local up="${MAX_UP_MBIT:-0}" down="${MAX_DOWN_MBIT:-0}"
  if [ "$up" -gt 0 ] 2>/dev/null; then
    tc qdisc replace dev eth0 root tbf rate "${up}mbit" burst 64kb latency 400ms \
      || echo "[shaper] WARNING: could not apply egress cap (missing NET_ADMIN?)"
  else
    tc qdisc del dev eth0 root 2>/dev/null || true
  fi
  if [ "$down" -gt 0 ] 2>/dev/null; then
    { tc qdisc replace dev eth0 handle ffff: ingress \
        && tc filter replace dev eth0 parent ffff: protocol all prio 1 u32 \
             match u32 0 0 police rate "${down}mbit" burst 1m drop; } \
      || echo "[shaper] WARNING: could not apply ingress cap (missing NET_ADMIN?)"
  else
    tc qdisc del dev eth0 ingress 2>/dev/null || true
  fi
  echo "[shaper] up=${up}mbit down=${down}mbit (0 = unlimited)"
}
shape

# --- tailscale (containerboot: tailscaled + tailscale up + serve config) ----
containerboot > >(prefix tailscale) 2>&1 &
TS_PID=$!

# --- restic rest-server (append-only, htpasswd, prometheus on :8000) --------
rest-server --path /data --append-only \
  --htpasswd-file /config/restic/.htpasswd \
  --prometheus --prometheus-no-auth > >(prefix rest-server) 2>&1 &
REST_PID=$!

# --- alloy telemetry (best-effort restart loop) -----------------------------
(
  while :; do
    alloy run /etc/alloy/config.alloy --storage.path=/var/lib/alloy
    echo "alloy exited ($?), restarting in 15s"
    sleep 15
  done
) > >(prefix alloy) 2>&1 &
ALLOY_PID=$!

term() { kill "$TS_PID" "$REST_PID" "$ALLOY_PID" 2>/dev/null; }
trap term TERM INT

# Exit when either critical process dies; docker restarts the whole container,
# so the "never restart tailscale alone" failure mode no longer exists.
wait -n "$TS_PID" "$REST_PID"
rc=$?
echo "[supervisor] critical process exited ($rc), shutting down"
term
exit "$rc"
