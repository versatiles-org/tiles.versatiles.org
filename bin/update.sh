#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# update.sh — pull latest code, rebuild, refresh tile data, rolling reload.
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
#        Fetches each dataset's MD5 from the CDN, compares with local
#        state. Writes a transitional versatiles.yaml:
#          - local path for current datasets
#          - local path (old file) for stale datasets that have a local file and
#            an atomic build — they keep serving the old data during the rebuild
#          - CDN URL only for datasets with no local file or a delete-old-first
#            build (e.g. satellite)
#        Does NOT download. Exit codes:
#          0 → at least one file needs updating
#          1 → pipeline error (abort)
#          2 → nothing to update (skip intermediate restart)
#
#   4. (only if step 3 returned 0) reload versatiles
#        Tile server picks up the transitional config and serves stale
#        tilesets from the CDN so it stays available while step 5 downloads
#        the new files. Reload is a no-downtime SIGHUP (see step 6).
#
#   5. download-updater --mode=finalize  (Phase 2)
#        Deletes stale local files and (re)builds missing/changed datasets —
#        most are downloaded, derived datasets (satellite, osm) are rebuilt with
#        versatiles convert (see download/sources.json). Then rewrites
#        versatiles.yaml to serve everything via each dataset's serveCurrent.
#
#   6. reload versatiles (config-aware)
#        Tile server picks up the final local-disk config. Recreates the
#        container only when compose-level state changed (new image, env,
#        mounts); otherwise sends SIGHUP so the running container reloads the
#        new versatiles.yaml with no downtime (tile sources updated
#        incrementally, in-flight requests complete).
#        Exception: when step 2 refreshed the frontend/styles tars, the
#        fallback is a full restart instead of SIGHUP — see $VERSATILES_FALLBACK
#        below for why a reload cannot pick those up.
#
#   7. reload nginx (config-aware)
#        Re-resolves the versatiles upstream in case the tile server container
#        was recreated above (new IP); nginx caches upstream IPs from config
#        load until reloaded. Also the only step that applies nginx config
#        changes pulled in step 1, since it re-renders the templates. Recreates
#        the nginx container only when its compose state changed; otherwise
#        sends a graceful `nginx -s reload`.
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
#     The tile server is reloaded twice (transitional config, then final).
#     During the gap, stale tilesets are served from the CDN so there is no
#     outage; the SIGHUP reloads themselves are also downtime-free.
#
#   Path B — nothing changed (prepare exits 2):
#     1 → 2 → 3 → 7 → 9   (plus 6 and 8 when step 2 fetched new assets)
#     Steps 4 and 5 are skipped: tile data is already current, so the existing
#     healthy state is preserved. Steps 1 and 2 still run so frontend / styles
#     / Docker image updates are picked up even when no tile data needs
#     refreshing — and when they were, 6 reloads the tile server and 8 drops
#     the now-stale assets from the cache. Step 7 always runs, because nginx
#     config arrives with step 1 and nothing else would apply it; here it
#     reloads in place, never recreating the container. Verification (9)
#     catches infra drift (expired certs, etc).
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

# How to make the tile server pick up new config/assets when `docker compose up`
# leaves the container untouched (see up_with_config_fallback in helpers.sh).
#
# SIGHUP is the cheap, downtime-free path and is enough for tile data: the
# download pipeline rewrites each dataset's `src:` in versatiles.yaml, so the
# reload sees a changed config and swaps the sources.
#
# It is NOT enough for the frontend/styles tars. Their `static:` entries name
# fixed paths (/data/frontend/frontend.br.tar, styles.tar) that are identical
# before and after a release, and versatiles' reload diffs the *config*, not the
# file contents — apply_static_source_diff() returns early on an unchanged
# static section. The tar is read into memory in full at load time, so the
# container keeps serving the bytes it read at startup: a SIGHUP after a
# frontend update is a silent no-op and the old frontend stays live.
#
# So when build.sh refreshed the assets, force a restart, which re-reads the
# tars. `docker compose restart` reuses the container, so nginx's cached
# upstream IP stays valid; it costs a few seconds of refused requests.
if [ "$ASSETS_CHANGED" = "true" ]; then
  VERSATILES_FALLBACK=restart
else
  VERSATILES_FALLBACK=sighup
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
  # served by the versatiles container from a tar and cached by nginx, so the
  # download alone does nothing visible — without a restart and cache clear the
  # old frontend keeps being served. So when assets changed we restart the tile
  # server ($VERSATILES_FALLBACK is `restart` in that case, since a SIGHUP reload
  # would not re-read the tars) and clear the cache here even though no tile data
  # moved.
  if [ "$ASSETS_CHANGED" = "true" ]; then
    echo "Tile data unchanged, but frontend/styles changed — restarting tile server."
    up_with_config_fallback versatiles "$VERSATILES_FALLBACK"
    wait_for_healthy versatiles
  else
    echo "Nothing to update — skipping finalize and tile server restart."
  fi

  # nginx is reloaded even when nothing above ran. Its config reaches the
  # container only through a re-render of nginx/templates/*.template — and those
  # templates change with this repo's git HEAD, which neither $ASSETS_CHANGED nor
  # the prepare exit code tracks. Without this, a config change pulled in step 1
  # (a new redirect, a cache rule) would sit dormant until the next run that
  # happens to touch tile data.
  #
  # Unlike step 7 on the tile path, this reloads in place rather than going
  # through `docker compose up`: on a run where nothing else changed, a base
  # image pulled in step 2 is not worth a container recreate and the brief
  # refused connections that come with it. That image lands on the next Path A
  # run. Reloading in place is graceful and drops nothing.
  echo "Reloading nginx..."
  reload_nginx_in_place
  wait_for_healthy nginx

  # Only the assets are newly served, so only they can be stale in the cache.
  if [ "$ASSETS_CHANGED" = "true" ]; then
    echo "Clearing cache data..."
    ./bin/ramdisk/clear.sh
  fi

  echo ""
  echo "Running verification..."
  ./bin/verify.sh
  echo "Operations completed successfully."
  exit 0
fi

# Files need updating — have the tile server pick up the transitional config and
# serve stale tilesets from the CDN while we download the new files. The `sighup`
# fallback recreates the container only if compose state changed; otherwise it
# sends SIGHUP so versatiles reloads the new yaml with no downtime.
echo "Reloading tile server with CDN fallback config..."
up_with_config_fallback versatiles sighup
wait_for_healthy versatiles

# Phase 2: delete stale files, download new ones, generate final configs
echo "Running download pipeline (finalize)..."
docker compose run --rm download-updater --mode=finalize

# Tile server picks up the final local-disk config. Normally a SIGHUP reload with
# no downtime; a restart when the frontend/styles tars changed, which a reload
# cannot pick up (see $VERSATILES_FALLBACK above).
echo "Reloading tile server with local files..."
up_with_config_fallback versatiles "$VERSATILES_FALLBACK"
wait_for_healthy versatiles

# Reload nginx so it re-resolves the versatiles upstream. If the tile server
# container was recreated above (e.g. after an image update via `compose pull`),
# its IP may have changed, and nginx caches upstream IPs from config-load time
# until reloaded — without this it would keep proxying to the old IP (502s).
echo "Reloading nginx..."
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
