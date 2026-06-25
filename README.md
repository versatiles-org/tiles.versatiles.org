[![CI status](https://img.shields.io/github/actions/workflow/status/versatiles-org/tiles.versatiles.org/ci.yml)](https://github.com/versatiles-org/tiles.versatiles.org/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

# tiles.versatiles.org

Production setup for serving VersaTiles map tiles with nginx reverse proxy, SSL via Let's Encrypt, and RAM disk caching.

This repository serves **tiles.versatiles.org** (tile serving). The file downloads at **download.versatiles.org** are served separately from Cloudflare R2 and are maintained in the [download.versatiles.org](https://github.com/versatiles-org/download.versatiles.org) repository — they are no longer part of this setup.

## Features

- **Tile Serving**: Fast tile delivery via VersaTiles server with nginx caching
- **Caching**: RAM disk cache for fast tile serving
- **SSL**: Automatic Let's Encrypt certificates
- **Security**: Rate limiting, anonymized logging, no-new-privileges containers
- **Health checks**: Container health monitoring for all services

## Architecture

- **versatiles**: Tile server serving `.versatiles` files from local disk
- **download-updater**: One-shot pipeline that produces the local `.versatiles` files in `volumes/tiles/` from the CDN (cdn.versatiles.cloud) and generates `versatiles.yaml` for the tile server. Each dataset is defined declaratively in [`download/sources.json`](download/sources.json) — most are mirrored as-is (aria2c), some are derived with [VPL](https://docs.versatiles.org) via `versatiles convert`
- **nginx**: Reverse proxy in front of the tile server (TLS termination, caching, rate limiting)
- **certbot**: SSL certificate management

The inputs are hosted on a Cloudflare bucket behind **cdn.versatiles.cloud** (each is a stable `<slug>.versatiles` key with a `.md5` sidecar). The `download-updater` keeps a local copy so the tile server reads from fast local disk; while a dataset is updating, the tile server temporarily reads it from the CDN so there is no downtime. No credentials are involved — the CDN is public.

**Derived datasets** (configured in [`download/sources.json`](download/sources.json), see [`download/README.md`](download/README.md)):

- `/tiles/satellite/` — too large to mirror in full (~2 TB), so only z0–15 is kept locally (~700 GB) and z16+ is served straight from the CDN, stacked via a VPL pipeline.
- `/tiles/osm/` — served from the prebuilt **`osm-landcover.versatiles`** on the CDN (osm + landcover merged upstream, attribution baked in). It's a plain mirror under a remapped name; `landcover-vectors` is **not** served on its own.

## Volume Directories

All persistent data is stored under `./volumes/` and bind-mounted into Docker containers. Created by `bin/deploy/setup.sh`.

| Directory                      | Purpose                               | Mode  | Owner       | Writer           | Reader(s)         |
|--------------------------------|---------------------------------------|-------|-------------|------------------|-------------------|
| `volumes/tiles/`               | Downloaded `.versatiles` tile files   | rw/ro | `1001:1001` | download-updater | versatiles        |
| `volumes/versatiles_conf/`     | Generated `versatiles.yaml` (+ `.vpl`) | rw/ro | `1001:1001` | download-updater | versatiles        |
| `volumes/frontend/`            | Built frontend assets (HTML, JS, CSS) | ro    | root        | Host scripts     | versatiles        |
| `volumes/cache/`               | Nginx tile cache (RAM disk / tmpfs)   | rw    | root        | nginx (UID 101)  | nginx             |
| `volumes/certbot-cert/`        | Let's Encrypt certificates            | rw    | root        | certbot          | —                 |
| `volumes/certbot-www/`         | ACME challenge files                  | rw/ro | root        | certbot          | nginx             |
| `volumes/nginx-cert/`          | SSL certs copied for nginx            | ro    | root        | Host scripts     | nginx             |
| `volumes/nginx-log/`           | Nginx access/error logs               | rw    | root        | nginx (UID 101)  | Host scripts      |

**Mode** shows container mount modes. `rw/ro` means the writer mounts read-write, readers mount read-only.

`volumes/tiles/` can be relocated to another filesystem via the `TILES_DIR` setting — see [Relocating tile storage](#relocating-tile-storage).

### Permissions

- **download-updater volumes** (`tiles/`, `versatiles_conf/`): Must be owned by UID 1001 (`appuser` inside the container). The setup script runs `chown 1001:1001` on these after creation.
- **nginx writable volumes** (`cache/`, `nginx-log/`): nginx master starts as root and manages file ownership internally. `cache/` is a tmpfs mount recreated on each boot.
- **certbot volumes** (`certbot-cert/`, `certbot-www/`): Certbot runs as root — default ownership works.
- **Host-written volumes** (`frontend/`, `nginx-cert/`): Written by host scripts (running as root), mounted read-only in containers.

### Troubleshooting

If download-updater fails with `EACCES` errors, fix ownership:
```bash
chown 1001:1001 volumes/tiles volumes/versatiles_conf
```

Run `./bin/verify.sh` to check all volume directories exist and have correct ownership.

## Server Installation

### 1. Install Dependencies (Debian/Ubuntu)

```bash
apt-get update && apt-get -y upgrade
apt-get -y install git wget ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update && apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
shutdown -r now
```

### 2. Clone Repository

```bash
git clone https://github.com/versatiles-org/tiles.versatiles.org.git
cd tiles.versatiles.org
```

### 3. Configure Environment

```bash
cp template.env .env
nano .env
```

### 4. Deploy

```bash
./bin/deploy/setup.sh
```

This runs preflight checks and then sets up everything: volumes, RAM disk, frontend, styles, Docker images, SSL certificates, and all services. It downloads the full tile data to local disk before starting, which can take a long time.

#### Fast start

To get the server live in minutes without waiting for the (large) tile download:

```bash
./bin/deploy/setup.sh --fast
```

This sets up everything as above but writes a **transient config** that serves every dataset straight from the CDN (no tile download, no tile disk used). The server is immediately available — just slower per tile. When ready, run `./bin/update.sh` to download the data and switch to local-disk serving **with no downtime**.

## Configuration

Edit `.env` to configure:

| Variable            | Description                                     | Example                         |
|---------------------|-------------------------------------------------|---------------------------------|
| `DOMAIN_NAME`  | Tiles domain                                      | tiles.versatiles.org         |
| `RAM_DISK_GB`  | RAM disk size for caching                         | 4                            |
| `EMAIL`        | Email for Let's Encrypt                           | mail@versatiles.org          |
| `CDN_BASE_URL` | CDN hosting the tile data (optional, has default) | https://download.versatiles.org |
| `TILES_DIR`    | Tile data directory — relocate to another filesystem if needed (optional, defaults to `./volumes/tiles`) | /mnt/bigdisk/tiles |

No credentials are required — the tile data is fetched from the public CDN.

### Relocating tile storage

`volumes/tiles/` holds the `.versatiles` files and is by far the largest volume (hundreds of GB). To put it on another filesystem, set `TILES_DIR` in `.env` to an absolute path **before** running `bin/deploy/setup.sh` (or run `bin/deploy/ensure.sh` after changing it — it creates the directory and sets ownership to `1001:1001`). The container-internal paths are unchanged, so nothing else needs adjusting. To migrate an existing install: stop the stack, move the files to the new location, set `TILES_DIR`, then `./bin/deploy/ensure.sh` and restart.

## Operations

### Update After Code Changes

When the repository code has been updated (e.g., new features, bug fixes):

```bash
./bin/update.sh
```

The script runs a safe two-phase update that keeps the tile server available throughout. Here are all the steps in order:

**1. `git pull`** — pull the latest code.

**2. `bin/deploy/build.sh`**
- `bin/deploy/ensure.sh` — create volume directories, fix ownership, init RAM disk, configure cron jobs
- `bin/frontend/update.sh` — fetch latest frontend assets
- `bin/styles/update.sh` — fetch latest map styles
- `docker compose pull` — pull latest Docker images
- `docker compose build download-updater` — rebuild the download-updater image

**3. download-updater `--mode=prepare`** (Phase 1) — compares each dataset against the CDN and writes a *transitional* `versatiles.yaml`: current datasets stay on local disk, stale/missing ones point at the CDN so they keep serving during the update. Downloads nothing. **Exits 0** if anything needs updating, or **exits 2** if everything is already current (in which case steps 4–7 are skipped). Mode, comparison, and exit-code details: [`download/README.md`](download/README.md).

**4. *(only if prepare exited 0)* Reload tile server — CDN fallback config**
```bash
up_with_config_fallback versatiles sighup   # docker compose up; SIGHUP if unchanged
```
VersaTiles reloads `versatiles.yaml` on SIGHUP with no downtime (it's recreated only if the compose state changed, e.g. a new image). Datasets that need updating are now served from the CDN — slower, but available. Old local files can now be safely deleted.

**5. download-updater `--mode=finalize`** (Phase 2) — deletes datasets no longer listed and (re)builds new/changed ones: most are downloaded, derived datasets (e.g. satellite) are built with `versatiles convert`. Then writes the final `versatiles.yaml`. How builds and the generated config work: [`download/README.md`](download/README.md).

**6. Reload tile server — local files**
```bash
up_with_config_fallback versatiles sighup
```
VersaTiles reloads `versatiles.yaml` on SIGHUP (no downtime). Datasets are now served from local disk at full speed (satellite still reads its high zoom levels from the CDN).

**7. `bin/ramdisk/clear.sh`** — flush the nginx RAM disk cache so stale tiles are not served.

**8. `bin/verify.sh`** — smoke-test the live endpoints to confirm the deployment succeeded.

The tile server is always serving valid data: between steps 3 and 4 stale datasets come from cdn.versatiles.cloud; between steps 5 and 6 each dataset comes from local disk (satellite additionally reads its high zoom levels from the CDN). There is no moment where a tile request can fail.

### Ensure Infrastructure Only

To re-apply infrastructure prerequisites without a full update (e.g., after changing volume config or cron jobs):

```bash
./bin/deploy/ensure.sh
```

This is idempotent and safe to run repeatedly. It ensures:
- All volume directories exist with correct ownership
- RAM disk is mounted
- Cron jobs (cert renewal, log rotation) are configured

Both `bin/deploy/setup.sh` and `bin/update.sh` call this automatically.

### Update Tile Data

> **Prefer `./bin/update.sh` for production.** It runs the safe two-phase flow
> (serve stale datasets from the CDN while the new files download) so the tile
> server stays available throughout — see [Update After Code Changes](#update-after-code-changes).
>
> `bin/download-updater/update.sh` below is a simpler single-shot path intended
> for manual/dev use. It runs `finalize` and reloads the tile server via SIGHUP
> (no dropped connections). It skips the two-phase CDN fallback, though: a
> **derived** dataset (satellite, osm) is briefly unavailable while it is rebuilt
> in place, since there is no transitional switch to the CDN. Plain datasets are
> seamless (atomic temp→rename). Fine for a quick refresh; use `./bin/update.sh`
> when you need every dataset to stay available throughout.

When new `.versatiles` files have been published to the CDN:

```bash
./bin/download-updater/update.sh
```

This builds the updater image, runs it once (finalize) to sync changed files into `volumes/tiles/` and regenerate `versatiles.yaml`, and reloads the tile server (SIGHUP). For what the sync actually does, see [`download/README.md`](download/README.md).

### Switching serving mode (transient ↔ local)

Manually flip where the tile server reads its data, without downloading, building, or deleting anything. This only rewrites `versatiles.yaml` and reloads the tile server (SIGHUP, no downtime), so it is fast and reversible:

```bash
./bin/serve-mode.sh transient   # serve every dataset from the CDN
./bin/serve-mode.sh local       # serve datasets present on local disk from disk
```

- **`transient`** — serve all datasets straight from the CDN. Local tile files are left untouched, just not used. Useful to free the tile server from local data before moving/repairing the `volumes/tiles` volume, or to keep serving while local data is incomplete.
- **`local`** — serve each dataset whose local file exists from disk; any missing dataset falls back to the CDN. This is presence-based (it serves whatever is on disk), not a freshness check.

To actually **download or refresh** local data (and switch back to local serving as part of it), use `./bin/update.sh` — that's the full two-phase, no-downtime path. `serve-mode.sh` is only for flipping the active source.

### Certificate Renewal

Certificates are renewed automatically via weekly cron job. Manual renewal:
```bash
./bin/cert/renew.sh
```

### View Logs

```bash
docker compose logs -f           # All services
docker compose logs -f nginx     # Nginx only
```

### Referer statistics

nginx records a per-request referer log (`volumes/nginx-log/referer_stats*.tsv.gz`). Summarise it by referer domain — total transmitted data (MB) and number of tile requests — as an aligned table sorted by data descending:

```bash
./bin/log/referer_stats.sh                # current month (default)
./bin/log/referer_stats.sh --month all    # all months (live log + rotated files)
./bin/log/referer_stats.sh --month 2026-05  # a specific rotated month
```

The logs rotate monthly, so the timespan is selected by `--month` (`current`, `all`, or `YYYY-MM`). Explicit `*.tsv.gz` file arguments override `--month`.

For a per-month overview — tile requests, tile data, and total data per month — use:

```bash
./bin/log/monthly_traffic.sh
```

It prints one row per month (`month`, `tiles`, `tile_MB`, `total_MB`), oldest first with the current month last. With no arguments it reads all `referer_stats*.tsv.gz`; pass specific files to scope it.

## Development

This repository is shell scripts (`bin/`, `download/update-tiles.sh`), a Docker
Compose stack (`compose.yaml`), and nginx config (`nginx/`) — there is no
Node.js/npm component. The tile-data updater is a single bash script
(`download/update-tiles.sh`) running in a minimal Alpine container; see
[`download/README.md`](download/README.md) for its modes and pipeline.

### Prerequisites

- Docker + Docker Compose plugin
- [ShellCheck](https://www.shellcheck.net/) (for linting the scripts)

### Running the updater locally

```bash
docker compose build download-updater
docker compose run --rm download-updater --mode=check   # report only, no changes
```

## Contributing

Before submitting a PR, run the same checks as CI (`.github/workflows/ci.yml`):

1. ShellCheck passes: `shellcheck bin/**/*.sh download/update-tiles.sh`
2. Docker compose validates: `cp template.env .env && docker compose config --quiet`
3. YAML lints cleanly: `yamllint compose.yaml`
