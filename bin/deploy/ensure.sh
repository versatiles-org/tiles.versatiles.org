#!/usr/bin/env bash
set -euo pipefail

# Ensures infrastructure prerequisites are in place.
# Idempotent — safe to run repeatedly. Called by setup.sh and update.sh,
# or run manually after changing volumes, cron jobs, etc.

cd "$(dirname "$0")/../.."

# Tile data directory — can be relocated to another filesystem via TILES_DIR in
# .env (must match the value compose bind-mounts; default ./volumes/tiles).
[ -f .env ] && source .env
TILES_DIR="${TILES_DIR:-./volumes/tiles}"

echo "Ensuring infrastructure prerequisites..."

# 1. Volume directories
echo "Ensuring volume directories exist..."
mkdir -p \
	volumes/certbot-cert \
	volumes/certbot-www \
	volumes/nginx-cert \
	volumes/nginx-log \
	volumes/frontend volumes/cache \
	volumes/versatiles_conf \
	"$TILES_DIR"

echo "Ensuring volume ownership..."
chown -R 1001:1001 \
	"$TILES_DIR" \
	volumes/versatiles_conf

# 2. RAM disk
echo "Ensuring RAM disk..."
./bin/ramdisk/init.sh

# 3. Cron jobs
echo "Ensuring cron jobs..."
./bin/cert/setup_renewal.sh
./bin/log/setup_rotation.sh

echo "Infrastructure prerequisites OK."
