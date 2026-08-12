# offsite-backup-node

A self-contained, self-updating offsite backup target. One `docker compose up -d`
turns any box with docker into an **append-only restic REST server** reachable
only over a private [Tailscale](https://tailscale.com) network — nothing listens
on your LAN, all stored data is client-side encrypted, and the whole thing keeps
itself current from upstream images.

Built for the "host a backup box at a relative's house" use case: the person
running it needs zero maintenance and can never read the data.

## What runs

| Service | Image | Job |
|---|---|---|
| tailscale | `tailscale/tailscale` | joins the private network (userspace mode — no special caps); HTTPS via `tailscale serve` |
| rest-server | `restic/rest-server` | restic REST API, **append-only** (clients can write, never delete history), htpasswd auth |
| alloy | `grafana/alloy` | ships logs/metrics back to the operator over the same private network |
| watchtower | `containrrr/watchtower` | auto-updates the other three from their upstream publishers |

## Running it

You need two small files from whoever operates the backups (they contain the
private-network join key and the server password hash — deliberately not in
this repo): `.env` and `config/restic/.htpasswd`.

1. Docker + docker compose. **Unraid**: install the *Compose Manager* plugin
   (Apps) — Unraid ships docker without the compose command.
2. Clone this repo somewhere permanent (Unraid: under `/mnt/user/appdata/`).
3. Drop in the two provided files (`.env` next to the compose file, the
   htpasswd under `config/restic/`).
4. `docker compose up -d`

That's it. It enrolls itself on first boot (the join key burns after one use),
survives reboots and outages, updates itself, and never needs re-auth. Updates
to this repo: `git pull && docker compose up -d`.

> One operational rule: never restart the `tailscale` container alone — the
> other services live inside its network namespace and would be orphaned.
> Always `docker compose up -d --force-recreate` (or restart the whole stack).

## Configuration (`.env`)

```
OFFSITE_HOSTNAME=   # node name on the private network
TS_AUTHKEY=         # one-shot Tailscale auth key (only matters on first boot)
TS_LOGIN_SERVER=    # optional headscale URL; empty = Tailscale SaaS
CONFIG_ROOT=./config
DATA_PATH=          # absolute path to the disk that stores the backups
PROM_PUSH_URL=      # metrics receiver on the operator's bridge node
LOKI_PUSH_URL=      # log receiver on the operator's bridge node
```

## Bandwidth cap (yours)

If you don't want backup traffic saturating your connection, set
`MAX_DOWN_MBIT` (backups arriving) / `MAX_UP_MBIT` (restores leaving) in
`.env` and `docker compose restart shaper`. `0` — the default — means
unlimited. The cap is enforced on your box, by you: the backup sender can't
exceed it no matter what. (The shaper sidecar is the one component that needs
elevated network privileges, `NET_ADMIN`.)

## Trust properties

- **The host can't read the backups**: repositories hold restic's client-side
  encrypted blobs; decryption keys never touch this box in any form.
- **Clients can't destroy history**: `--append-only` means even a fully
  compromised backup client cannot delete or rewrite what's already stored.
- **No LAN exposure**: no published ports; the only way in is the private
  tailnet, gated by its ACLs plus htpasswd.
- **No secrets in this repo**: everything identifying or sensitive arrives via
  the two operator-provided files.
