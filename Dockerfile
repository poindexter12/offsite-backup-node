# Single-image backup node — ONE image, TWO roles (ROLE=offsite|bridge, see
# entrypoint.sh): the shipped offsite bundle and the estate-side bridge plane
# run the exact same artifact.
#
# Every binary is copied straight out of its official upstream image, onto the
# smallest practical base: tailscaled/containerboot, rest-server, and restic
# are static Go binaries; alloy is glibc-linked, which is what rules out
# alpine/distroless and sets the floor at debian-slim. Packages: iproute2 (tc
# shaping), ca-certificates (TLS to the tailscale control plane and push
# URLs), iptables (kernel-mode tailscale in the bridge role), busybox-static
# (crond for the bridge's copy-job), curl (copy-job ntfy alerts); bash and
# GNU sed for entrypoint.sh are already in debian-slim.
#
# The FROMs are ARG-parameterized so CI pins each upstream by digest and bakes
# those digests into labels — that's how the rebuild workflow detects upstream
# releases (see .github/workflows/build.yaml). Local `docker build .` still
# works, tracking :latest.

ARG TAILSCALE_IMAGE=tailscale/tailscale:latest
ARG REST_SERVER_IMAGE=restic/rest-server:latest
ARG ALLOY_IMAGE=grafana/alloy:latest
ARG RESTIC_IMAGE=restic/restic:latest
ARG BASE_IMAGE=debian:stable-slim

FROM ${TAILSCALE_IMAGE} AS tailscale
FROM ${REST_SERVER_IMAGE} AS rest-server
FROM ${ALLOY_IMAGE} AS alloy
FROM ${RESTIC_IMAGE} AS restic

FROM ${BASE_IMAGE}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        iproute2 ca-certificates iptables busybox-static curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscale /usr/local/bin/containerboot /usr/local/bin/
COPY --from=rest-server /usr/bin/rest-server /usr/local/bin/rest-server
COPY --from=alloy /usr/bin/alloy /usr/local/bin/alloy
COPY --from=restic /usr/bin/restic /usr/local/bin/restic

# Non-secret config baked in; runtime state and secrets still arrive via
# mounts. Both roles' alloy pipelines ship — entrypoint picks /etc/alloy/<ROLE>.alloy.
COPY config-template/alloy/offsite.alloy config-template/alloy/bridge.alloy /etc/alloy/
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
