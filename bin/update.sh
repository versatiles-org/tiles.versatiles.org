#!/usr/bin/env bash
set -euo pipefail

# Update script: pull latest code, rebuild, and do a rolling restart.
#
# Safe update pipeline (two phases):
#
# Phase 1 (prepare): determines which tile files need updating and generates
# transitional configs. Files that are stale or missing are served from remote
# WebDAV so the tile server stays available during the update.
# Exit code 2 means nothing needs updating — skip the intermediate restart.
#
# Phase 2 (finalize): deletes stale local files, downloads new ones, and
# regenerates configs pointing to local disk.

cd "$(dirname "$0")/.."
source bin/deploy/helpers.sh

# Update the repository with the latest changes from Git
echo "Updating repository from Git..."
git pull

# Build (ensure, fetch assets, pull/build images)
./bin/deploy/build.sh

# Phase 1: check what needs updating; generate transitional configs
echo "Running download pipeline (prepare)..."
set +e
docker compose run --rm download-updater --mode=prepare
PREPARE_EXIT=$?
set -e

if [ $PREPARE_EXIT -eq 1 ]; then
  echo "ERROR: Download pipeline (prepare) failed."
  exit 1
fi

if [ $PREPARE_EXIT -eq 0 ]; then
  # Files need updating — restart tile server to serve stale tilesets from WebDAV
  echo "Restarting tile server with WebDAV fallback..."
  docker compose up --detach --force-recreate versatiles
  wait_for_healthy versatiles
fi
# Exit code 2 means nothing to update — skip intermediate restart

# Phase 2: delete stale files, download new ones, generate final configs
echo "Running download pipeline (finalize)..."
docker compose run --rm download-updater --mode=finalize

# Restart tile server with final local-disk config
echo "Restarting tile server with local files..."
docker compose up --detach --force-recreate versatiles
wait_for_healthy versatiles

# Recreate nginx last (backends are already up and healthy)
echo "Updating nginx..."
docker compose up --detach --force-recreate nginx
wait_for_healthy nginx

# Clear cache data
echo "Clearing cache data..."
./bin/ramdisk/clear.sh

# Verify deployment
echo ""
echo "Running verification..."
./bin/verify.sh

echo "Operations completed successfully."
