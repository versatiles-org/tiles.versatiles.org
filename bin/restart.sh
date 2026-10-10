#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# restart.sh — restart the running stack with as little downtime as possible.
# =============================================================================
#
# Usage:
#   restart.sh                Replace the tile server container, clear the cache.
#   restart.sh --with-nginx   Also recreate the nginx container (brief outage).
#   restart.sh --keep-cache   Leave the cached responses in place.
#
# This restarts what is already deployed: it pulls nothing, builds nothing, and
# does not touch tile data or versatiles.yaml. Use ./bin/update.sh to update,
# ./bin/serve-mode.sh to switch where tiles are served from.
#
# The steps:
#
#   1. replace the tile server container (replace_tile_server in helpers.sh)
#        A fresh container from the image and compose definition currently on
#        disk is started next to the running one; the old one is stopped only
#        once the new one is healthy. nginx follows Docker's DNS, so it moves
#        over on its own — no reload, and :80/:443 stay bound throughout.
#        This is the only way to re-read what versatiles reads once at startup —
#        above all the frontend/styles tars, which a SIGHUP reload cannot pick
#        up: it diffs the config, and their `static:` paths are the same before
#        and after a release.
#        If the new container does not become healthy, it is removed and the old
#        one keeps serving; the script stops there.
#
#   2. clear the cache (unless --keep-cache)
#        After the swap, so clients get what the new tile server holds.
#
#   3. (--with-nginx only) recreate the nginx container
#        Needed solely for a new base image or changed ports/volumes/env/logging
#        — a reload already applies config, template and certificate changes.
#        This is the one step with unavoidable downtime: only one container can
#        hold the published ports, so :80/:443 are unbound and new connections
#        are refused until the replacement listens — about 3 seconds (see
#        recreate_nginx in helpers.sh). It runs last, so that is the only such
#        window.
# =============================================================================

cd "$(dirname "$0")/.."
source bin/deploy/helpers.sh

WITH_NGINX=false
KEEP_CACHE=false
for arg in "$@"; do
	case "$arg" in
		--with-nginx) WITH_NGINX=true ;;
		--keep-cache) KEEP_CACHE=true ;;
		-h|--help)
			sed -n '8,15p' "$0"
			exit 0
			;;
		*)
			echo "Unknown argument: $arg"
			echo "Usage: $0 [--with-nginx] [--keep-cache]"
			exit 1
			;;
	esac
done

# Only one update/restart/serve-mode run at a time.
acquire_deploy_lock

# 1. Fresh tile server container, started before the old one is stopped.
replace_tile_server

# 2. Drop cached responses so clients see what the new tile server holds.
if [ "$KEEP_CACHE" = "true" ]; then
	echo "Keeping cached responses (--keep-cache)."
else
	echo "Clearing cache data..."
	./bin/ramdisk/clear.sh
fi

# 3. Optional nginx container replacement. A recreate re-renders the templates
#    at entrypoint, so it needs no reload afterwards.
if [ "$WITH_NGINX" = "true" ]; then
	recreate_nginx
fi

echo ""
echo "Restart complete. Run ./bin/verify.sh for a full post-deploy check."
