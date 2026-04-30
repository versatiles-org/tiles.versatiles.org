#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# update.sh — pull latest code, rebuild, refresh tile data, rolling restart.
# =============================================================================
#
# Steps (top to bottom in this script):
#
#   1. git pull
#        Pull the latest code from the repository.
#
#   2. ./bin/deploy/build.sh
#        - ensure infrastructure (volumes, RAM disk, cron jobs)
#        - fetch frontend + styles
#        - docker compose pull / build
#        NOTE: build.sh currently *also* runs the download pipeline in
#        finalize mode. That call short-circuits the prepare/finalize design
#        below and should be moved to setup.sh — see the improvement plan.
#
#   3. download-updater --mode=prepare   (Phase 1)
#        Scans remote storage via SSH, hashes files, compares with local
#        state. Writes transitional configs:
#          - versatiles.yaml  → local paths for current files,
#                               WebDAV URLs for stale/missing files
#          - download.conf    → local alias for current files,
#                               WebDAV proxy for stale/missing files
#        Does NOT download. Exit codes:
#          0 → at least one file needs updating
#          1 → pipeline error (abort)
#          2 → nothing to update (skip intermediate restart)
#
#   4. (only if step 3 returned 0) restart versatiles
#        Tile server picks up the transitional config and serves stale
#        tilesets through the WebDAV fallback so it stays available
#        while step 5 downloads the new files.
#
#   5. download-updater --mode=finalize  (Phase 2)
#        Deletes stale local files, downloads missing/changed files,
#        regenerates the static site (HTML + RSS), and rewrites
#        versatiles.yaml + download.conf to point entirely to local disk.
#
#   6. restart versatiles
#        Tile server picks up the final local-disk config.
#
#   7. recreate nginx
#        Picks up the regenerated download.conf. Done last so the public
#        edge only flips after both backends are healthy.
#
#   8. ./bin/ramdisk/clear.sh
#        Drops the tile cache so clients don't get cached responses for
#        tiles whose underlying file has just been replaced.
#
#   9. ./bin/verify.sh
#        Post-deploy smoke test (HTTP/HTTPS endpoints, certs, configs).
#
# -----------------------------------------------------------------------------
# Execution paths
# -----------------------------------------------------------------------------
#
#   Path A — files changed (prepare exits 0):
#     1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9
#     Tile server is restarted twice (transitional config, then final).
#     During the gap between restarts, stale tilesets are served via
#     WebDAV proxy so there is no outage.
#
#   Path B — nothing changed (prepare exits 2):
#     1 → 2 → 3 → 5 → 6 → 7 → 8 → 9
#     The intermediate restart at step 4 is skipped, but steps 5–8 still
#     run today. They are effectively no-ops on data but still:
#       - rescan remote storage (step 5)
#       - force-recreate both containers (steps 6, 7)
#       - flush a warm cache (step 8)
#     Improving this is tracked in the update.sh improvement plan.
#
#   Path C — error during prepare (exit 1):
#     1 → 2 → 3 → abort. No restart, no config change.
# =============================================================================

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
