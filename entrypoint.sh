#!/bin/bash
# Supervisor for the backup node. One source, two roles (ROLE):
#
#   offsite (default) — the shipped bundle at the relative's house, from the
#     SLIM image (no alloy): userspace tailscale (zero device deps), inbound
#     via `tailscale serve` (:80 rest-server, :9002 tailscaled metrics — the
#     estate bridge SCRAPES those over the tailnet; nothing pushes metrics),
#     and a curl/jq log shipper that forwards the node's own logs to the
#     bridge through tailscaled's outbound proxy.
#   bridge — the estate-side plane, from the :bridge image (adds alloy +
#     restic). Kernel-mode tailscale (NET_ADMIN + /dev/net/tun from compose),
#     rest-server published on the LAN by compose, alloy scrapes the offsite
#     node over the tailnet and relays everything to the estate observability
#     stack, busybox crond runs the nightly restic copy-job (COPY_ENABLED).
#
# Process policy: containerboot and rest-server are critical — death exits the
# container and docker restarts everything together. Telemetry (alloy or the
# log shipper) is best-effort and must never take down the backup target.
#
# Local log hygiene: every service line tees to /var/log/node.log; a 60s
# rotation loop truncates it past 10MB unconditionally (the shipper truncates
# far earlier once lines are delivered). Telemetry may be lossy by design —
# it must NEVER accumulate on the host.
set -u

ROLE="${ROLE:-offsite}"

case "$ROLE" in
  offsite) ;;
  bridge)
    export TS_USERSPACE=false
    unset TS_SERVE_CONFIG TS_SOCKS5_SERVER TS_OUTBOUND_HTTP_PROXY_LISTEN
    command -v alloy >/dev/null || { echo "[supervisor] ROLE=bridge needs the :bridge image (alloy missing)"; exit 1; }
    ;;
  *) echo "[supervisor] unknown ROLE '$ROLE' (offsite|bridge)"; exit 1 ;;
esac
echo "[supervisor] role: $ROLE"

# Refuse to run with an unmounted /data: backups written into the container's
# own filesystem would silently fill the host's docker storage (on Unraid,
# the fixed-size docker.img — a whole-host outage). Fail fast and loud.
if ! mountpoint -q /data; then
  echo "[supervisor] FATAL: /data is not a mounted volume — refusing to write backups into the container filesystem. Map a host path to /data."
  exit 1
fi
mountpoint -q /var/lib/tailscale || \
  echo "[supervisor] WARNING: /var/lib/tailscale is not a mounted volume — the node identity will NOT survive a container recreate (re-enrollment will need a fresh auth key)."

NODE_LOG=/var/log/node.log
: > "$NODE_LOG"
prefix() { sed -u "s/^/[$1] /" | tee -a "$NODE_LOG"; }

# --- local log bound (both roles): never past 10MB, checked every 60s -------
( while :; do
    sleep 60
    [ "$(stat -c%s "$NODE_LOG" 2>/dev/null || echo 0)" -gt 10485760 ] && : > "$NODE_LOG"
  done ) &

# --- bandwidth shaping (MAX_UP_MBIT / MAX_DOWN_MBIT, 0 = unlimited) ---------
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
# Auth arrives either as a mounted file (compose bundles) or as the
# REST_HTPASSWD env var holding the "user:bcrypt-hash" line (env-only setups,
# e.g. the Unraid container template — no operator files needed).
HTPASSWD_FILE=/config/restic/.htpasswd
if [ ! -f "$HTPASSWD_FILE" ] && [ -n "${REST_HTPASSWD:-}" ]; then
  printf '%s\n' "$REST_HTPASSWD" > /run/restic-htpasswd
  chmod 600 /run/restic-htpasswd
  HTPASSWD_FILE=/run/restic-htpasswd
  echo "[rest-server] using htpasswd from REST_HTPASSWD env"
fi
rest-server --path /data --append-only \
  --htpasswd-file "$HTPASSWD_FILE" \
  --prometheus --prometheus-no-auth > >(prefix rest-server) 2>&1 &
REST_PID=$!

# --- offsite: own-log shipper (loki JSON push through tailscaled's proxy) ---
# Best-effort and bounded: lines that fail to ship are eventually truncated
# by the rotation loop — telemetry loss is acceptable, local buildup is not.
# Diagnostics go straight to stdout (NOT via prefix — no feedback loop).
SHIP_PID=""
if [ "$ROLE" = "offsite" ] && [ -n "${LOKI_PUSH_URL:-}" ]; then
  (
    off=0
    while :; do
      sleep 15
      size=$(stat -c%s "$NODE_LOG" 2>/dev/null || echo 0)
      [ "$size" -lt "$off" ] && off=0   # rotated behind us
      if [ "$size" -gt "$off" ]; then
        chunk=$(tail -c +"$((off+1))" "$NODE_LOG" | head -c 1048576)
        n=$(printf '%s' "$chunk" | wc -c)
        payload=$(printf '%s' "$chunk" | jq -Rn --arg ts "$(date +%s%N)" \
          '{streams:[{stream:{site:"offsite",stack:"backups",job:"node"},values:[inputs | select(length>0) | [$ts, .]]}]}') || { off=$((off+n)); continue; }
        if curl -fsS -m 15 -x http://127.0.0.1:1055 \
             -H 'Content-Type: application/json' -d "$payload" \
             "$LOKI_PUSH_URL" >/dev/null 2>&1; then
          off=$((off+n))
        fi
      fi
      # aggressive local hygiene: once everything is shipped, reclaim early
      [ "$size" -gt 2097152 ] && [ "$off" -ge "$size" ] && { : > "$NODE_LOG"; off=0; }
    done
  ) &
  SHIP_PID=$!
  echo "[log-shipper] shipping $NODE_LOG -> $LOKI_PUSH_URL (batched, bounded)"
elif [ "$ROLE" = "offsite" ]; then
  echo "[log-shipper] disabled (LOKI_PUSH_URL empty) — local 10MB bound still enforced"
fi

# --- bridge: alloy relay (scrapes the offsite node; best-effort loop) -------
ALLOY_PID=""
if [ "$ROLE" = "bridge" ]; then
  (
    resolve_offsite() { tailscale ip -4 "${OFFSITE_HOST:-jacaranda-offsite}" 2>/dev/null; }
    while :; do
      # Resolve the offsite peer through tailscaled's netmap — MagicDNS never
      # reaches libc here (--accept-dns=false). tailscaled may still be
      # booting (or the offsite node not yet enrolled): retry for ~60s, then
      # fall back and let the change-watcher below catch up later.
      ADDR=""
      for _ in $(seq 1 12); do
        ADDR=$(resolve_offsite) && [ -n "$ADDR" ] && break
        sleep 5
      done
      [ -n "$ADDR" ] || ADDR=127.0.0.1
      echo "offsite scrape target: ${OFFSITE_HOST:-jacaranda-offsite} -> $ADDR"
      OFFSITE_ADDR="$ADDR" alloy run /etc/alloy/bridge.alloy --storage.path=/var/lib/alloy &
      APID=$!
      # Restart alloy if the peer's address changes (first enrollment, or a
      # re-enrolled node getting a new IP).
      while kill -0 "$APID" 2>/dev/null; do
        sleep 300
        NEW=$(resolve_offsite) || NEW=""
        if [ -n "$NEW" ] && [ "$NEW" != "$ADDR" ]; then
          echo "offsite address changed ($ADDR -> $NEW), restarting alloy"
          kill "$APID"
          break
        fi
      done
      wait "$APID" 2>/dev/null
      echo "alloy exited, restarting in 15s"
      sleep 15
    done
  ) > >(prefix alloy) 2>&1 &
  ALLOY_PID=$!
fi

# --- bridge: copy-job crond (best-effort restart loop) ----------------------
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

term() { kill "$TS_PID" "$REST_PID" ${ALLOY_PID:+"$ALLOY_PID"} ${SHIP_PID:+"$SHIP_PID"} ${CRON_PID:+"$CRON_PID"} 2>/dev/null; }
trap term TERM INT

# Exit when either critical process dies; docker restarts the whole container,
# so partial-stack states are impossible by construction.
wait -n "$TS_PID" "$REST_PID"
rc=$?
echo "[supervisor] critical process exited ($rc), shutting down"
term
exit "$rc"
