#!/usr/bin/env bash
set -euo pipefail

# Ensures infrastructure prerequisites are in place.
# Idempotent — safe to run repeatedly. Called by setup.sh and update.sh,
# or run manually after changing volumes, cron jobs, etc.

cd "$(dirname "$0")/../.."

echo "Ensuring infrastructure prerequisites..."

# 1. Volume directories
echo "Ensuring volume directories exist..."
mkdir -p \
	volumes/certbot-cert \
	volumes/certbot-www \
	volumes/download/content \
	volumes/download/hash_cache \
	volumes/download/nginx_conf \
	volumes/nginx-cert \
	volumes/nginx-log \
   volumes/frontend volumes/cache \
   volumes/tiles

echo "Ensuring volume ownership..."
chown -R 1001:1001 \
	volumes/download/hash_cache \
	volumes/download/nginx_conf \
   volumes/download/content \
   volumes/tiles

# 2. RAM disk
echo "Ensuring RAM disk..."
./bin/ramdisk/init.sh

# 3. Cron jobs
echo "Ensuring cron jobs..."
./bin/cert/setup_renewal.sh
./bin/log/setup_rotation.sh

echo "Infrastructure prerequisites OK."
