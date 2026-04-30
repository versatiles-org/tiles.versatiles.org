#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# update.sh — pull latest code, rebuild, refresh tile data, rolling restart.
# =============================================================================
#
# Usage:
#   update.sh             Run the full update pipeline (paths A/B/C below).
#   update.sh --dry-run   Read-only check: fetch git (no pull), run the
#                         download pipeline in check mode, report what
#                         would change. Touches no configs, no containers,
#                         no cache. Safe to run from cron.
#
# Steps (top to bottom in this script):
#
#   1. git pull
#        Pull the latest code from the repository. Records the HEAD before
#        and after to decide whether step 2 is needed.
#
#   2. ./bin/deploy/build.sh   (only when step 1 pulled new commits)
#        - ensure infrastructure (volumes, RAM disk, cron jobs)
#        - fetch frontend + styles
#        - docker compose pull / build
#        Skipped when HEAD is unchanged: docker images, frontend assets,
#        and styles only change via committed code.
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
#   6. restart versatiles (config-aware)
#        Tile server picks up the final local-disk config. Recreates the
#        container only when compose-level state changed (new image, env,
#        mounts); otherwise issues a lighter `docker compose restart` so
#        the existing container re-reads the new versatiles.yaml.
#
#   7. reload nginx (config-aware)
#        Picks up the regenerated download.conf. Recreates the container
#        only when compose-level state changed; otherwise sends a graceful
#        SIGHUP via `nginx -s reload`, preserving warm connections.
#        Done last so the public edge only flips after backends are healthy.
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
#     1 → [2] → 3 → 4 → 5 → 6 → 7 → 8 → 9
#     Step 2 runs only if step 1 pulled new commits. The tile server is
#     restarted twice (transitional config, then final). During the gap
#     between restarts, stale tilesets are served via WebDAV proxy so
#     there is no outage.
#
#   Path B — nothing changed (prepare exits 2):
#     1 → [2] → 3 → 9
#     The script exits early after prepare when no remote files are
#     newer than what is already on disk. Step 2 still runs if there
#     were code changes, but steps 4–8 are skipped — the existing
#     healthy state and warm cache are preserved. Verification (9)
#     still runs to catch infrastructure drift (expired certs, etc).
#
#   Path C — error during prepare (exit 1):
#     1 → [2] → 3 → abort. No restart, no config change.
# =============================================================================

cd "$(dirname "$0")/.."
source bin/deploy/helpers.sh

# Argument parsing
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      sed -n '4,18p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg"
      echo "Usage: $0 [--dry-run]"
      exit 1
      ;;
  esac
done

# Dry-run: report what *would* happen without changing anything. Runs
# `git fetch` (no pull) to detect pending commits, then runs the download
# pipeline in `check` mode (no downloads, no config writes, no static site).
if [ "$DRY_RUN" = "true" ]; then
  echo "DRY RUN — no changes will be applied."
  echo ""

  echo "Checking for new commits..."
  git fetch --quiet
  AHEAD=$(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo "0")
  if [ "$AHEAD" -gt 0 ]; then
    echo "  $AHEAD commit(s) pending on upstream:"
    git log --oneline 'HEAD..@{u}' | sed 's/^/    /'
  else
    echo "  Code is up to date."
  fi
  echo ""

  echo "Checking remote tile data..."
  set +e
  docker compose run --rm download-updater --mode=check
  CHECK_EXIT=$?
  set -e
  echo ""

  case $CHECK_EXIT in
    0) echo "Result: tile data updates available — run 'update.sh' to apply." ;;
    2) echo "Result: tile data is up to date." ;;
    *) echo "Result: check failed (exit $CHECK_EXIT)."; exit 1 ;;
  esac
  exit 0
fi

# 1. Pull latest code. Skip the rebuild step when nothing was pulled —
#    docker images, frontend assets, and styles only change via committed
#    code, so an unchanged HEAD means there is nothing new to build.
echo "Updating repository from Git..."
PRE_PULL_HEAD=$(git rev-parse HEAD)
git pull
POST_PULL_HEAD=$(git rev-parse HEAD)

if [ "$PRE_PULL_HEAD" = "$POST_PULL_HEAD" ]; then
  echo "No new commits — skipping build."
else
  echo "New commits pulled (${PRE_PULL_HEAD:0:7} → ${POST_PULL_HEAD:0:7}). Building..."
  ./bin/deploy/build.sh
fi

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

if [ $PREPARE_EXIT -eq 2 ]; then
  # Nothing to update — local tiles are already current and configs already
  # point to local disk. Skip finalize, restarts, and cache clear; still run
  # verify.sh as a smoke test in case infra has drifted independently.
  echo "Nothing to update — skipping finalize, restart, and cache clear."
  echo ""
  echo "Running verification..."
  ./bin/verify.sh
  echo "Operations completed successfully."
  exit 0
fi

# Files need updating — restart tile server so it picks up the transitional
# config and serves stale tilesets through the WebDAV fallback while we
# download the new files. Use `restart` fallback so we only recreate the
# container if compose state changed; otherwise just re-read the new yaml.
echo "Restarting tile server with WebDAV fallback..."
up_with_config_fallback versatiles restart
wait_for_healthy versatiles

# Phase 2: delete stale files, download new ones, generate final configs
echo "Running download pipeline (finalize)..."
docker compose run --rm download-updater --mode=finalize

# Tile server picks up the final local-disk config.
echo "Restarting tile server with local files..."
up_with_config_fallback versatiles restart
wait_for_healthy versatiles

# Nginx picks up the regenerated download.conf. Use `reload` fallback so we
# send a graceful SIGHUP when only the conf changed; recreate only when the
# compose state itself changed (new image, new env, new mounts).
echo "Updating nginx..."
up_with_config_fallback nginx reload
wait_for_healthy nginx

# Clear cache data
echo "Clearing cache data..."
./bin/ramdisk/clear.sh

# Verify deployment
echo ""
echo "Running verification..."
./bin/verify.sh

echo "Operations completed successfully."
