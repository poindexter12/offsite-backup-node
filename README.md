# offsite-backup-node

A self-contained offsite backup target in **one docker image / one container**
(`ghcr.io/poindexter12/offsite-backup-node`). One `docker compose up -d` turns
any box with docker into an **append-only restic REST server** reachable only
over a private [Tailscale](https://tailscale.com) network — nothing listens on
your LAN, all stored data is client-side encrypted, and CI keeps the image
current with its upstreams.

Built for the "host a backup box at a relative's house" use case: the person
running it needs near-zero maintenance and can never read the data.

## What runs (inside the one container)

The image is assembled from official upstream images — the binaries are copied
straight out of `tailscale/tailscale`, `restic/rest-server`, and
`grafana/alloy` at build time onto a minimal `debian:stable-slim` base
(tailscaled and rest-server are static; alloy is the one glibc-linked binary,
which is what rules out alpine/distroless) — and a small supervisor
(`entrypoint.sh`) runs them as one unit:

| Process | From | Job |
|---|---|---|
| tailscaled | `tailscale/tailscale` | joins the private network (userspace mode); HTTPS via `tailscale serve` |
| rest-server | `restic/rest-server` | restic REST API, **append-only** (clients can write, never delete history), htpasswd auth |
| alloy | `grafana/alloy` | ships logs/metrics back to the operator over the same private network |
| tc shaping | iproute2 | applies your bandwidth caps at startup (the reason the container has `NET_ADMIN`) |

Lifecycle: tailscaled and rest-server are critical — if either dies, the
container exits and docker restarts everything together (no more
"never restart the tailscale container alone" foot-gun; partial restarts are
impossible by construction). Alloy is best-effort: telemetry failure never
takes down the backup target.

## Running it

You need two small files from whoever operates the backups (they contain the
private-network join key and the server password hash — deliberately not in
this repo): `.env` and `config/restic/.htpasswd`.

1. Any Linux machine with Docker and the docker compose plugin installed.
2. Clone this repo somewhere permanent (e.g. `/opt/offsite-backup-node`).
3. Drop in the two provided files (`.env` next to the compose file, the
   htpasswd under `config/restic/`).
4. `docker compose up -d`

That's it. It enrolls itself on first boot (the join key burns after one use)
and survives reboots and outages — `config/tailscaled` persists the identity,
so the node never re-enrolls.

## Updates

We build and publish our own image. A GitHub Actions workflow
(`.github/workflows/build.yaml`) checks the four upstreams — `tailscale/tailscale`,
`restic/rest-server`, `grafana/alloy`, and the `debian:stable-slim` base —
every 6 hours (watchtower's old poll interval) and rebuilds/publishes
`ghcr.io/poindexter12/offsite-backup-node` whenever any of them releases. The
exact upstream digests that went into a build are pinned at build time and
baked into the image's `io.offsite-backup.upstream-digests` label, which is
also how the workflow detects change.

Images are multi-arch (amd64 + arm64) and the package is public — no registry
login anywhere. Every publish is tagged `latest` plus a timestamp tag
(e.g. `20260813-2234`); to roll back, set that tag on the `image:` line in
`docker-compose.yaml` and `docker compose up -d`.

The box picks updates up with:

```sh
cd /opt/offsite-backup-node && git pull -q && docker compose pull -q && docker compose up -d
```

To keep it hands-off, put that in cron (e.g. daily):

```cron
0 4 * * * cd /opt/offsite-backup-node && git pull -q && docker compose pull -q && docker compose up -d 2>&1 | logger -t offsite-backup-update
```

## Development

To build and run the image locally instead of pulling from GHCR:
`docker compose up -d --build`. Local builds track the upstreams' `:latest`
tags; CI builds pin exact digests.

## Configuration (`.env`)

All options, with defaults (see `env.example`):

| Variable | Default | Purpose |
|---|---|---|
| `OFFSITE_HOSTNAME` | `offsite-backup` | node name on the private network (also the container hostname) |
| `TS_AUTHKEY` | *(empty)* | one-shot Tailscale auth key — only matters on first boot; the node never re-enrolls |
| `TS_LOGIN_SERVER` | *(empty)* | optional self-hosted control server URL (headscale); empty = Tailscale SaaS |
| `CONFIG_ROOT` | `./config` | directory holding all persistent component state (tailscale identity, htpasswd, alloy WAL) |
| `DATA_PATH` | **required** | absolute path to the disk/directory that stores the backups |
| `PROM_PUSH_URL` | *(empty)* | metrics receiver on the operator's bridge node |
| `LOKI_PUSH_URL` | *(empty)* | log receiver on the operator's bridge node |
| `MAX_DOWN_MBIT` | `0` | bandwidth cap on incoming backup traffic, Mbit/s; `0` = unlimited |
| `MAX_UP_MBIT` | `0` | bandwidth cap on outgoing restore/telemetry traffic, Mbit/s; `0` = unlimited |

## Bandwidth cap (yours)

If you don't want backup traffic saturating your connection, set
`MAX_DOWN_MBIT` (backups arriving) / `MAX_UP_MBIT` (restores leaving) in
`.env` and `docker compose up -d` (compose recreates the container when its
environment changes; caps apply at startup). `0` — the default — means
unlimited. The cap is enforced on your box, by you: the backup sender can't
exceed it no matter what. This shaping is why the container carries the
`NET_ADMIN` capability.

## Trust properties

- **The host can't read the backups**: repositories hold restic's client-side
  encrypted blobs; decryption keys never touch this box in any form.
- **Clients can't destroy history**: `--append-only` means even a fully
  compromised backup client cannot delete or rewrite what's already stored.
- **No LAN exposure**: no published ports; the only way in is the private
  tailnet, gated by its ACLs plus htpasswd.
- **No secrets in this repo**: everything identifying or sensitive arrives via
  the two operator-provided files.
- **No secrets in the image**: the image bakes in only tracked, non-secret
  config (`serve.json`, the alloy template); identity and credentials arrive
  via mounts and environment at run time.
