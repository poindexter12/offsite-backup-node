# Single-image offsite backup node: tailscale + restic rest-server + alloy
# telemetry + tc bandwidth shaping, supervised by entrypoint.sh.
#
# Every binary is copied straight out of its official upstream image, onto the
# smallest practical base: tailscaled/containerboot and rest-server are static
# Go binaries; alloy is glibc-linked, which is what rules out alpine/distroless
# and sets the floor at debian-slim (+ iproute2 for tc, + ca-certificates for
# TLS to the tailscale control plane and telemetry push URLs; bash and GNU sed
# for entrypoint.sh are already in debian-slim).
#
# The FROMs are ARG-parameterized so CI pins each upstream by digest and bakes
# those digests into labels — that's how the rebuild workflow detects upstream
# releases (see .github/workflows/build.yaml). Local `docker build .` still
# works, tracking :latest.

ARG TAILSCALE_IMAGE=tailscale/tailscale:latest
ARG REST_SERVER_IMAGE=restic/rest-server:latest
ARG ALLOY_IMAGE=grafana/alloy:latest
ARG BASE_IMAGE=debian:stable-slim

FROM ${TAILSCALE_IMAGE} AS tailscale
FROM ${REST_SERVER_IMAGE} AS rest-server
FROM ${ALLOY_IMAGE} AS alloy

FROM ${BASE_IMAGE}

RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscale /usr/local/bin/containerboot /usr/local/bin/
COPY --from=rest-server /usr/bin/rest-server /usr/local/bin/rest-server
COPY --from=alloy /usr/bin/alloy /usr/local/bin/alloy

# Non-secret config baked in; runtime state and secrets still arrive via mounts.
COPY config-template/alloy/config.alloy /etc/alloy/config.alloy
COPY serve.json /config/serve.json
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# CI passes the exact upstream digests this build consumed; the scheduled
# workflow compares these labels against current upstream digests to decide
# whether a rebuild is due. Empty on local builds.
ARG UPSTREAM_DIGESTS=""
LABEL org.opencontainers.image.source="https://github.com/poindexter12/offsite-backup-node" \
      io.offsite-backup.upstream-digests="${UPSTREAM_DIGESTS}"

# containerboot reads the TS_* env; these are the invariants — identity/auth
# (TS_AUTHKEY, TS_HOSTNAME, TS_EXTRA_ARGS) come from the environment at run time.
ENV TS_STATE_DIR=/var/lib/tailscale \
    TS_SERVE_CONFIG=/config/serve.json \
    TS_AUTH_ONCE=true \
    TS_USERSPACE=true \
    TS_ENABLE_METRICS=true

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
