#!/bin/sh
# Launch the offsite backup node — one container, no compose needed.
# Run from the bundle folder: ./run.sh  (re-run any time; it recreates.)
# Needs: docker. Reads .env next to this script.
set -eu
cd "$(dirname "$0")"

IMAGE="ghcr.io/poindexter12/offsite-backup-node:latest"
NAME="jacaranda-offsite"

fail() { echo "ERROR: $1" >&2; exit 1; }

# --- self-diagnosis: the two operator-provided files, before touching docker.
# (.env and config/restic/.htpasswd are HIDDEN files — GUI unzip/copy tools
# sometimes silently drop them. If either is missing, re-extract the zip from
# a shell: unzip jacaranda-offsite.zip)
[ -f .env ] || fail "missing .env next to run.sh (hidden file — was the zip extracted with a GUI tool that skipped dotfiles?)"
[ -f config/restic/.htpasswd ] || fail "missing config/restic/.htpasswd (hidden file — same cause as above; re-extract the zip from a shell)"

# shellcheck disable=SC1091
. ./.env
: "${DATA_PATH:?DATA_PATH must be set in .env (absolute path to the backup disk/directory)}"
[ -d "$DATA_PATH" ] || fail "DATA_PATH=$DATA_PATH does not exist on this machine — edit .env to point at the backup disk"

mkdir -p config/tailscaled config/alloy

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker pull -q "$IMAGE"
docker run -d --name "$NAME" \
  --hostname "${OFFSITE_HOSTNAME:-jacaranda-offsite}" \
  --restart unless-stopped \
  --cap-add NET_ADMIN \
  -e TS_AUTHKEY="${TS_AUTHKEY:-}" \
  -e TS_HOSTNAME="${OFFSITE_HOSTNAME:-jacaranda-offsite}" \
  ${TS_LOGIN_SERVER:+-e TS_EXTRA_ARGS=--login-server=${TS_LOGIN_SERVER}} \
  -e PROM_PUSH_URL="${PROM_PUSH_URL:-}" \
  -e LOKI_PUSH_URL="${LOKI_PUSH_URL:-}" \
  -e MAX_UP_MBIT="${MAX_UP_MBIT:-0}" \
  -e MAX_DOWN_MBIT="${MAX_DOWN_MBIT:-0}" \
  -v "$PWD/config/tailscaled:/var/lib/tailscale" \
  -v "$PWD/config/restic:/config/restic:ro" \
  -v "$PWD/config/alloy:/var/lib/alloy" \
  -v "$DATA_PATH:/data" \
  "$IMAGE" >/dev/null

echo "started. status:  docker logs -f $NAME"
sleep 8
docker exec "$NAME" tailscale status 2>/dev/null | head -3 || echo "(tailscale still starting — check: docker logs $NAME)"
