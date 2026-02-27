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

Interactive setup:
```bash
./bin/deploy/setup-env.sh
```

Or manually:
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

### 5. Run Pre-flight Checks

```bash
./bin/deploy/preflight.sh
```

### 6. Deploy

```bash
./bin/deploy/migrate.sh
```

### 7. Verify Deployment

```bash
./bin/verify.sh
```

## Configuration

Edit `.env` to configure:

| Variable          | Description                    | Example                 |
|-------------------|--------------------------------|-------------------------|
| `DOMAIN_NAME`     | Tiles domain                   | tiles.versatiles.org    |
| `DOWNLOAD_DOMAIN` | Downloads domain               | download.versatiles.org |
| `RAM_DISK_GB`     | RAM disk size for caching      | 4                       |
| `EMAIL`           | Email for Let's Encrypt        | mail@versatiles.org     |
| `STORAGE_URL`     | Storage box SSH URL            | user@host.de            |
| `STORAGE_PASS`    | Storage box password (WebDAV)  | (password)              |

## Operations

### Update After Code Changes

When the repository code has been updated (e.g., new features, bug fixes):

```bash
./bin/update.sh
```

This will:
- Pull latest changes from Git
- Update frontend assets
- Download latest tile data
- Rebuild and restart all Docker containers
- Regenerate download nginx configuration

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

## Rollback

If migration fails:
```bash
./bin/deploy/rollback.sh
```

Then update DNS to point download.versatiles.org back to the old server.

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
