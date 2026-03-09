[![CI status](https://img.shields.io/github/actions/workflow/status/versatiles-org/tiles.versatiles.org/ci.yml)](https://github.com/versatiles-org/tiles.versatiles.org/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

# tiles.versatiles.org

Production setup for serving VersaTiles map tiles and downloads with nginx reverse proxy, SSL via Let's Encrypt, and RAM disk caching.

This repository serves both **tiles.versatiles.org** (tile serving) and **download.versatiles.org** (file downloads) from a single server.

## Features

- **Tile Serving**: Fast tile delivery via VersaTiles server with nginx caching
- **Download Service**: Versioned file downloads via WebDAV proxy to remote storage
- **Caching**: RAM disk cache for fast tile serving
- **SSL**: Automatic Let's Encrypt certificates with OCSP stapling
- **Security**: Rate limiting, anonymized logging, no-new-privileges containers
- **Health checks**: Container health monitoring for all services

## Architecture

- **versatiles**: Tile server serving .versatiles files
- **download-updater**: One-shot pipeline that scans remote storage via SSH, generates nginx config with WebDAV proxy
- **nginx**: Reverse proxy for both domains (proxies to WebDAV for remote files)
- **certbot**: SSL certificate management

## Volume Directories

All persistent data is stored under `./volumes/` and bind-mounted into Docker containers. Created by `bin/deploy/setup.sh`.

| Directory                      | Purpose                               | Mode  | Owner       | Writer           | Reader(s)         |
|--------------------------------|---------------------------------------|-------|-------------|------------------|-------------------|
| `volumes/tiles/`               | Downloaded `.versatiles` tile files   | rw/ro | `1001:1001` | download-updater | versatiles, nginx |
| `volumes/frontend/`            | Built frontend assets (HTML, JS, CSS) | ro    | root        | Host scripts     | versatiles        |
| `volumes/cache/`               | Nginx tile cache (RAM disk / tmpfs)   | rw    | root        | nginx (UID 101)  | nginx             |
| `volumes/download/content/`    | Generated download page (HTML, RSS)   | rw/ro | `1001:1001` | download-updater | nginx             |
| `volumes/download/nginx_conf/` | Generated nginx config for downloads  | rw/ro | `1001:1001` | download-updater | nginx             |
| `volumes/download/hash_cache/` | Hash cache for download pipeline      | rw    | `1001:1001` | download-updater | —                 |
| `volumes/certbot-cert/`        | Let's Encrypt certificates            | rw    | root        | certbot          | —                 |
| `volumes/certbot-www/`         | ACME challenge files                  | rw/ro | root        | certbot          | nginx             |
| `volumes/nginx-cert/`          | SSL certs copied for nginx            | ro    | root        | Host scripts     | nginx             |
| `volumes/nginx-log/`           | Nginx access/error logs               | rw    | root        | nginx (UID 101)  | Host scripts      |

**Mode** shows container mount modes. `rw/ro` means the writer mounts read-write, readers mount read-only.

### Permissions

- **download-updater volumes** (`tiles/`, `download/content/`, `download/nginx_conf/`, `download/hash_cache/`): Must be owned by UID 1001 (`appuser` inside the container). The setup script runs `chown 1001:1001` on these after creation.
- **nginx writable volumes** (`cache/`, `nginx-log/`): nginx master starts as root and manages file ownership internally. `cache/` is a tmpfs mount recreated on each boot.
- **certbot volumes** (`certbot-cert/`, `certbot-www/`): Certbot runs as root — default ownership works.
- **Host-written volumes** (`frontend/`, `nginx-cert/`): Written by host scripts (running as root), mounted read-only in containers.

### Troubleshooting

If download-updater fails with `EACCES` errors, fix ownership:
```bash
chown 1001:1001 volumes/tiles volumes/download/content \
    volumes/download/nginx_conf volumes/download/hash_cache
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

### 4. Setup SSH Key for Storage Box

```bash
mkdir -p .ssh
# Copy your storage box SSH key
cp /path/to/storage-key .ssh/storage
chmod 600 .ssh/storage
```

### 5. Deploy

```bash
./bin/deploy/setup.sh
```

This runs preflight checks and then sets up everything: volumes, RAM disk, frontend, styles, Docker images, SSL certificates, and all services.

## Configuration

Edit `.env` to configure:

| Variable          | Description                   | Example                 |
|-------------------|-------------------------------|-------------------------|
| `DOMAIN_NAME`     | Tiles domain                  | tiles.versatiles.org    |
| `DOWNLOAD_DOMAIN` | Downloads domain              | download.versatiles.org |
| `RAM_DISK_GB`     | RAM disk size for caching     | 4                       |
| `EMAIL`           | Email for Let's Encrypt       | mail@versatiles.org     |
| `STORAGE_URL`     | Storage box SSH URL           | user@host.de            |
| `STORAGE_PASS`    | Storage box password (WebDAV) | (password)              |

## Operations

### Update After Code Changes

When the repository code has been updated (e.g., new features, bug fixes):

```bash
./bin/update.sh
```

This will:
- Ensure infrastructure (volumes, RAM disk, cron jobs)
- Pull latest changes from Git
- Update frontend assets
- Download latest tile data
- Rebuild and restart all Docker containers
- Regenerate download nginx configuration

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

### Update After Remote Storage Changes

When new `.versatiles` files have been added to the remote storage:

```bash
./bin/download-updater/update.sh
```

This will:
- Scan remote storage for new/updated files
- Regenerate the download page (HTML, RSS feeds)
- Update nginx configuration for new files
- Reload nginx to serve new files

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

## Development

### Prerequisites

- Node.js 22+
- npm

### Setup

```bash
cd download
npm install
```

### Running locally

```bash
npm run once    # Run pipeline once
```

### Linting and Testing

```bash
npm run lint       # Check for lint errors
npm run lint:fix   # Auto-fix lint errors
npm test           # Run tests
npm run test:watch # Run tests in watch mode
npm run typecheck  # TypeScript type checking
```

## Contributing

Before submitting a PR, ensure:

1. All tests pass: `cd download && npm test`
2. Linting passes: `npm run lint`
3. TypeScript compiles: `npm run typecheck`
4. ShellCheck passes: `shellcheck bin/**/*.sh`
5. Docker compose validates: `docker compose config --quiet`
