# Backup node — one source, two published images:
#
#   target `offsite` → :latest  (~225MB) — the shipped bundle. tailscale +
#     rest-server + curl/jq log shipper. NO alloy (the estate bridge scrapes
#     metrics over the tailnet instead; logs ship via a tiny curl loop), NO
#     restic, NO iptables (userspace tailscale needs none of it).
#   target `bridge`  → :bridge — a strict superset: adds alloy (scrape/relay),
#     restic (nightly copy-job), iptables (kernel-mode tailscale), busybox
#     (crond). Runs on the estate VMs where image size is irrelevant.
#
# Every binary is copied straight out of its official upstream image, onto
# debian-slim (alloy is glibc-linked, which rules out alpine/distroless; the
# rest are static Go). The FROMs are ARG-parameterized so CI pins each
# upstream by digest and bakes those digests into labels — that's how the
# rebuild workflow detects upstream releases (see .github/workflows/build.yaml).
# Local `docker build .` yields the bridge (final) stage; use
# `--target offsite` (or the compose build target) for the slim image.

ARG TAILSCALE_IMAGE=tailscale/tailscale:latest
ARG REST_SERVER_IMAGE=restic/rest-server:latest
ARG ALLOY_IMAGE=grafana/alloy:latest
ARG RESTIC_IMAGE=restic/restic:latest
ARG BASE_IMAGE=debian:stable-slim

FROM ${TAILSCALE_IMAGE} AS tailscale
FROM ${REST_SERVER_IMAGE} AS rest-server
FROM ${ALLOY_IMAGE} AS alloy
FROM ${RESTIC_IMAGE} AS restic

# ============================================================================
FROM ${BASE_IMAGE} AS offsite

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        iproute2 ca-certificates curl jq \
    && rm -rf /var/lib/apt/lists/*

COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscale /usr/local/bin/containerboot /usr/local/bin/
COPY --from=rest-server /usr/bin/rest-server /usr/local/bin/rest-server

COPY serve.json /config/serve.json
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# CI passes the exact upstream digests this build consumed; the scheduled
# workflow compares these labels against current upstream digests to decide
# whether a rebuild is due. Empty on local builds.
ARG UPSTREAM_DIGESTS=""
LABEL org.opencontainers.image.source="https://github.com/poindexter12/offsite-backup-node" \
      io.offsite-backup.upstream-digests="${UPSTREAM_DIGESTS}"

# containerboot reads the TS_* env; these are the offsite-role defaults — the
# entrypoint overrides the mode/serve/proxy vars for ROLE=bridge, and
# identity/auth (TS_AUTHKEY, TS_HOSTNAME, TS_EXTRA_ARGS) come from the
# environment at run time.
ENV TS_STATE_DIR=/var/lib/tailscale \
    TS_SERVE_CONFIG=/config/serve.json \
    TS_AUTH_ONCE=true \
    TS_USERSPACE=true \
    TS_ENABLE_METRICS=true \
    TS_SOCKS5_SERVER=localhost:1055 \
    TS_OUTBOUND_HTTP_PROXY_LISTEN=localhost:1055

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# ============================================================================
FROM offsite AS bridge

RUN apt-get update \
    && apt-get install -y --no-install-recommends iptables busybox-static \
    && rm -rf /var/lib/apt/lists/*

COPY --from=alloy /usr/bin/alloy /usr/local/bin/alloy
COPY --from=restic /usr/bin/restic /usr/local/bin/restic
COPY config-template/alloy/bridge.alloy /etc/alloy/bridge.alloy
