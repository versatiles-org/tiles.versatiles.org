#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# restart.sh — restart the running stack with as little downtime as possible.
# =============================================================================
#
# Usage:
#   restart.sh                Recreate the tile server, reload nginx, clear cache.
#   restart.sh --with-nginx   Also recreate the nginx container (brief outage).
#   restart.sh --keep-cache   Leave the cached responses in place.
#
# This restarts what is already deployed: it pulls nothing, builds nothing, and
# does not touch tile data or versatiles.yaml. Use ./bin/update.sh to update,
# ./bin/serve-mode.sh to switch where tiles are served from.
#
# Why the steps are ordered the way they are:
#
#   1. docker compose up --force-recreate versatiles
#        Replaces the tile server with a fresh container from the image and
#        compose state currently on disk. This is the only way to re-read what
#        versatiles reads once at startup — above all the frontend/styles tars,
#        which a SIGHUP reload cannot pick up: it diffs the config, and their
#        `static:` paths are the same before and after a release.
#        nginx is not touched, so :80/:443 stay bound throughout and no client
#        ever gets a refused connection.
#
#   2. reload nginx — immediately, before waiting for health
#        The new container has a new IP, and nginx resolves `server
#        versatiles:8080` once, at config-load time. Until it is reloaded it
#        proxies to the old, now-dead address, where packets are dropped rather
#        than refused — requests hang until proxy_connect_timeout (60s by
#        default) instead of failing fast. So the reload comes before
#        wait_for_healthy: the health check has a 10s start_period and a 30s
#        interval, and aiming nginx at a black hole for that long is far worse
#        than aiming it at a container that is merely still booting.
#        Once re-resolved, what the tile server cannot answer yet comes from the
#        cache — `proxy_cache_use_stale ... http_502` in
#        nginx/templates/proxy.conf.template keeps cached URLs served across the
#        few seconds of startup. Only uncached URLs see an error.
#
#   3. wait for the tile server to report healthy.
#
#   4. clear the cache (unless --keep-cache)
#        Last, deliberately: the cache is what covers steps 2 and 3, so dropping
#        it first would turn every request during startup into a real error.
#
#   5. (--with-nginx only) recreate the nginx container
#        Needed solely for a new base image or changed ports/volumes/env — a
#        reload already applies config, template and certificate changes. This
#        is the one step with unavoidable downtime: only one container can hold
#        the published ports, so :80/:443 are unbound for a moment and
#        connections are refused until the replacement listens. It runs last, so
#        that is the only such window.
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

# 1. Fresh tile server container.
echo "Recreating the tile server..."
docker compose up --detach --force-recreate versatiles

# 2. Point nginx at the new container before waiting for that container to come
#    up. reload_nginx_in_place() reloads gracefully when nginx is running and
#    brings it up when it is not; either way the listening sockets survive.
echo "Re-resolving the tile server upstream in nginx..."
reload_nginx_in_place

# 3. Now wait for the new tile server.
wait_for_healthy versatiles

# 4. Drop cached responses so clients see what the restarted server now holds.
if [ "$KEEP_CACHE" = "true" ]; then
	echo "Keeping cached responses (--keep-cache)."
else
	echo "Clearing cache data..."
	./bin/ramdisk/clear.sh
fi

# 5. Optional nginx container replacement. A recreate re-renders the templates
#    at entrypoint, so it needs no reload afterwards.
if [ "$WITH_NGINX" = "true" ]; then
	echo "Recreating the nginx container (ports briefly unavailable)..."
	docker compose up --detach --force-recreate nginx
	wait_for_healthy nginx
fi

echo ""
echo "Restart complete. Run ./bin/verify.sh for a full post-deploy check."
