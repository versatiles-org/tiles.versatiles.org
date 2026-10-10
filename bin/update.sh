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
#   4. (only if step 3 returned 0) reload the tile server
#        Tile server picks up the transitional config and serves stale
#        tilesets from the CDN so it stays available while step 5 downloads
#        the new files. Same mechanism as step 6.
#
#   5. download-updater --mode=finalize  (Phase 2)
#        Deletes stale local files and (re)builds missing/changed datasets —
#        most are downloaded, derived datasets (satellite) are rebuilt with
#        versatiles convert (see download/sources.json). Then rewrites
#        versatiles.yaml to serve everything via each dataset's serveCurrent.
#
#   6. reload the tile server (apply_tile_server in helpers.sh)
#        Tile server picks up the final local-disk config. Normally a SIGHUP:
#        the running container reloads the new versatiles.yaml in place (tile
#        sources updated incrementally, in-flight requests complete).
#        The container is replaced instead when it is out of date (new image
#        pulled in step 2, changed definition in compose.yaml) or when step 2
#        refreshed the frontend/styles tars, which a reload cannot pick up —
#        see $TILE_SERVER_MODE below. Replacing is gap-free: the new container
#        starts next to the old one, which is stopped once the new one is
#        healthy.
#
#   7. reload nginx
#        Applies nginx config changes pulled in step 1 by re-rendering the
#        templates, then a graceful `nginx -s reload`. If the nginx container
#        itself is out of date (new image, changed definition in compose.yaml)
#        it is recreated instead, on both paths — the one step that refuses
#        connections for a moment. nginx follows the tile server through
#        Docker's DNS, so it needs no reload for a new tile server container.
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
#     In between, stale tilesets are served from the CDN so there is no
#     outage.
#
#   Path B — no new tile data (prepare exits 2):
#     1 → 2 → 3 → 7 → 9   (plus 6 and 8 when the tile server must be replaced)
#     Steps 4 and 5 are skipped: tile data is already current. Step 7 always
#     runs and comes first here, because nginx config arrives with step 1 and
#     nothing else would apply it; it reloads in place, or recreates the nginx
#     container if that is out of date. The tile
#     server container is replaced (6) when step 2 fetched a new frontend or
#     styles bundle, or when the container is out of date — a new image or a
#     changed compose.yaml — and the cache is cleared afterwards (8).
#     Verification (9) catches infra drift (expired certs, etc).
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

# How the tile server picks up what changed (see apply_tile_server in
# helpers.sh).
#
# SIGHUP is the cheapest path and is enough for tile data: the download pipeline
# rewrites each dataset's `src:` in versatiles.yaml, so the reload sees a
# changed config and swaps the sources.
#
# It is NOT enough for the frontend/styles tars. Their `static:` entries name
# fixed paths (/data/frontend/frontend.br.tar, styles.tar) that are identical
# before and after a release, and versatiles' reload diffs the *config*, not the
# file contents — apply_static_source_diff() returns early on an unchanged
# static section. The tar is read into memory in full at load time, so the
# container keeps serving the bytes it read at startup: a SIGHUP after a
# frontend update is a silent no-op and the old frontend stays live.
#
# So when build.sh refreshed the assets, the tile server container is replaced:
# a new one is started next to the old one and reads the new tars, and the old
# one is stopped once the new one is healthy — no gap.
#
# Independent of this choice, apply_tile_server replaces the container whenever
# it is out of date (a new image pulled in step 2, or a changed definition in
# compose.yaml), so a pending image is applied on every run, not only when tile
# data happens to change.
if [ "$ASSETS_CHANGED" = "true" ]; then
  TILE_SERVER_MODE=replace
else
  TILE_SERVER_MODE=sighup
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
  # and versatiles.yaml already points to local disk. Skip finalize.

  # nginx first, and always. Its config reaches the container only through a
  # re-render of nginx/templates/*.template — and those templates change with
  # this repo's git HEAD, which neither $ASSETS_CHANGED nor the prepare exit
  # code tracks. Without this, a config change pulled in step 1 (a new redirect,
  # a cache rule) would sit dormant until the next run that happens to touch
  # tile data.
  #
  # Normally that is a reload in place, which is graceful and drops nothing.
  # If the nginx container itself is out of date — a new image pulled in step 2,
  # or a changed definition in compose.yaml — it is recreated instead, which
  # also renders the templates. Unlike the tile server it cannot be swapped
  # without a gap: only one container can hold ports 80/443, so new connections
  # are refused for about 3 seconds (see recreate_nginx in helpers.sh). That is
  # accepted here so that a pending image never stays unapplied.
  if service_is_running nginx && service_has_pending_change nginx; then
    echo "The nginx container is out of date (new image or changed compose definition)."
    recreate_nginx
  else
    echo "Reloading nginx..."
    reload_nginx_in_place
    wait_for_healthy nginx
  fi

  # The tile server. Even without new tile data there are two reasons to replace
  # its container:
  #   - build.sh downloaded a new frontend/styles bundle. Those are served from
  #     a tar that versatiles reads only at startup (see $TILE_SERVER_MODE), so
  #     the download alone changes nothing a client can see.
  #   - the container is out of date: step 2 pulled a new image, or compose.yaml
  #     changed (a new version pin, mounts, logging limits, …).
  # Either way the replacement is gap-free (replace_tile_server), and the cache
  # is cleared afterwards — what the new container serves may differ.
  TILE_SERVER_REPLACED=false
  if [ "$ASSETS_CHANGED" = "true" ]; then
    echo "Tile data unchanged, but frontend/styles changed — replacing the tile server container."
    replace_tile_server
    TILE_SERVER_REPLACED=true
  elif service_has_pending_change versatiles; then
    echo "Tile data unchanged, but the tile server container is out of date (new image or changed compose definition) — replacing it."
    replace_tile_server
    TILE_SERVER_REPLACED=true
  else
    echo "Nothing to update — tile data, frontend, styles and the tile server container are current."
  fi

  if [ "$TILE_SERVER_REPLACED" = "true" ]; then
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
# serve stale tilesets from the CDN while we download the new files. Normally a
# SIGHUP, so versatiles reloads the new yaml in place; if the container is out
# of date (new image, changed compose definition) it is replaced without a gap
# instead, and the new container reads the transitional yaml.
echo "Reloading tile server with CDN fallback config..."
apply_tile_server sighup
wait_for_healthy versatiles

# Phase 2: delete stale files, download new ones, generate final configs
echo "Running download pipeline (finalize)..."
docker compose run --rm download-updater --mode=finalize

# Tile server picks up the final local-disk config. Normally a SIGHUP reload; a
# gap-free container replacement when the frontend/styles tars changed, which a
# reload cannot pick up (see $TILE_SERVER_MODE above).
echo "Reloading tile server with local files..."
apply_tile_server "$TILE_SERVER_MODE"
wait_for_healthy versatiles

# Apply the nginx config pulled in step 1 (re-render the templates, graceful
# reload). On this path the nginx container is also recreated if it is out of
# date (new base image, changed compose definition): a data update is a
# maintenance moment anyway, and the recreate costs about 3 seconds of
# refused connections. nginx finds the tile server through Docker's DNS, so it
# needs no reload just because the tile server container changed.
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
