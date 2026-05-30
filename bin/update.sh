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
#        Pull the latest code from the repository.
#
#   2. ./bin/deploy/build.sh
#        - ensure infrastructure (volumes, RAM disk, cron jobs)
#        - fetch latest versatiles-frontend release (HEAD-checked)
#        - fetch latest versatiles-style release (HEAD-checked)
#        - docker compose pull (versatiles, nginx base images)
#        - docker compose build download-updater (uses layer cache)
#        Always runs: each sub-step has its own idempotent freshness check.
#        We can't condition on "no new git commits" because frontend, styles,
#        and the published Docker images all release independently of this
#        repo's HEAD.
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
#     1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9
#     The tile server is restarted twice (transitional config, then final).
#     During the gap between restarts, stale tilesets are served via WebDAV
#     proxy so there is no outage.
#
#   Path B — nothing changed (prepare exits 2):
#     1 → 2 → 3 → 9
#     Steps 4–8 are skipped: tile data is already current and the existing
#     healthy state and warm cache are preserved. Steps 1 and 2 still run
#     so frontend / styles / Docker image updates are picked up even when
#     no tile data needs refreshing. Verification (9) catches infra drift
#     (expired certs, etc).
#
#   Path C — error during prepare (exit 1):
#     1 → 2 → 3 → abort. No restart, no config change.
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

# 1. Pull latest code from the repository.
echo "Updating repository from Git..."
git pull

# 2. Always run build.sh. Each of its steps is independently idempotent and
#    cheap when nothing has changed:
#      - bin/frontend/update.sh and bin/styles/update.sh check the latest
#        GitHub release tag via a HEAD request and only download on a change
#      - `docker compose pull` is a no-op when the registry hasn't moved
#      - `docker compose build download-updater` uses the layer cache
#    None of these track this repo's git HEAD, so we cannot use "no new
#    commits" as a skip signal — that would miss external releases of
#    versatiles-frontend, versatiles-style, the versatiles binary image,
#    and the nginx base image.
#
#    build.sh exits 10 when it actually refreshed the frontend and/or styles.
#    Those assets are served by the versatiles container from a tar it loads at
#    startup and are cached by nginx, so a download alone is not enough — the
#    container must be restarted and the cache cleared. In Path A both happen
#    anyway; in Path B (no tile changes) they are otherwise skipped, so we use
#    this flag to force them. See the Path B branch below.
set +e
./bin/deploy/build.sh
BUILD_EXIT=$?
set -e
if [ $BUILD_EXIT -eq 10 ]; then
  ASSETS_CHANGED=true
elif [ $BUILD_EXIT -ne 0 ]; then
  echo "ERROR: build.sh failed (exit $BUILD_EXIT)."
  exit 1
else
  ASSETS_CHANGED=false
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
  # Nothing in the tile data needs updating — local tiles are already current
  # and configs already point to local disk. Skip finalize and the tile-driven
  # restarts.
  #
  # BUT: build.sh may still have pulled a new frontend/styles bundle. Those are
  # loaded by the versatiles container at startup and cached by nginx, so the
  # download alone does nothing visible — without a restart and cache clear the
  # old frontend keeps being served. So when assets changed we restart the tile
  # server and clear the cache here even though no tile data moved.
  if [ "$ASSETS_CHANGED" = "true" ]; then
    echo "Tile data unchanged, but frontend/styles changed — restarting tile server and clearing cache."
    up_with_config_fallback versatiles restart
    wait_for_healthy versatiles
    ./bin/ramdisk/clear.sh
  else
    echo "Nothing to update — skipping finalize, restart, and cache clear."
  fi
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
