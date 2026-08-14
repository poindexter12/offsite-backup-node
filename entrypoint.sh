#!/bin/bash
# Supervisor for the single-image backup node. One image, two roles (ROLE):
#
#   offsite (default) — the shipped bundle at the relative's house. Userspace
#     tailscale (zero device deps), inbound via `tailscale serve`, alloy
#     PUSHES telemetry home through tailscaled's outbound proxy.
#   bridge — the estate-side plane. Kernel-mode tailscale (needs NET_ADMIN +
#     /dev/net/tun from compose — outbound tailnet dials for restic copy),
#     rest-server published on the LAN by compose, alloy RECEIVES the offsite
#     pushes and relays to the estate observability stack, and busybox crond
#     runs the nightly restic copy-job (COPY_ENABLED=true + mounted crontab).
#
# Process policy: containerboot and rest-server are critical — death exits the
# container and docker restarts everything together. alloy and crond are
# best-effort restart loops — telemetry/copy loss must never take down the
# backup target itself.
set -u

ROLE="${ROLE:-offsite}"

case "$ROLE" in
  offsite) ;;
  bridge)
    export TS_USERSPACE=false
    unset TS_SERVE_CONFIG TS_SOCKS5_SERVER TS_OUTBOUND_HTTP_PROXY_LISTEN
    ;;
  *) echo "[supervisor] unknown ROLE '$ROLE' (offsite|bridge)"; exit 1 ;;
esac
echo "[supervisor] role: $ROLE"

prefix() { sed -u "s/^/[$1] /"; }

# --- bandwidth shaping (MAX_UP_MBIT / MAX_DOWN_MBIT, 0 = unlimited) ---------
# tc caps on eth0; the container needs NET_ADMIN. Shaping failure is a
# warning, not fatal — an unshaped backup box still works.
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

# --- tailscale (containerboot: tailscaled + tailscale up [+ serve]) ---------
containerboot > >(prefix tailscale) 2>&1 &
TS_PID=$!

# --- restic rest-server (append-only, htpasswd, prometheus on :8000) --------
rest-server --path /data --append-only \
  --htpasswd-file /config/restic/.htpasswd \
  --prometheus --prometheus-no-auth > >(prefix rest-server) 2>&1 &
REST_PID=$!

# --- alloy telemetry (role-specific pipeline; best-effort restart loop) -----
(
  while :; do
    alloy run "/etc/alloy/${ROLE}.alloy" --storage.path=/var/lib/alloy
    echo "alloy exited ($?), restarting in 15s"
    sleep 15
  done
) > >(prefix alloy) 2>&1 &
ALLOY_PID=$!

# --- copy-job crond (bridge only; best-effort restart loop) -----------------
CRON_PID=""
if [ "$ROLE" = "bridge" ] && [ "${COPY_ENABLED:-false}" = "true" ]; then
  if [ -f /etc/crontabs/root ]; then
    (
      while :; do
        busybox crond -f -L /dev/stdout -c /etc/crontabs
        echo "crond exited ($?), restarting in 15s"
        sleep 15
      done
    ) > >(prefix copy-job) 2>&1 &
    CRON_PID=$!
  else
    echo "[copy-job] COPY_ENABLED=true but no crontab mounted at /etc/crontabs/root — skipping"
  fi
elif [ "$ROLE" = "bridge" ]; then
  echo "[copy-job] dormant (COPY_ENABLED != true)"
fi

term() { kill "$TS_PID" "$REST_PID" "$ALLOY_PID" ${CRON_PID:+"$CRON_PID"} 2>/dev/null; }
trap term TERM INT

# Exit when either critical process dies; docker restarts the whole container,
# so partial-stack states are impossible by construction.
wait -n "$TS_PID" "$REST_PID"
rc=$?
echo "[supervisor] critical process exited ($rc), shutting down"
term
exit "$rc"
