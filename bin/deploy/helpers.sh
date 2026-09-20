#!/usr/bin/env bash
# Shared helper functions for deploy scripts. Source this file, don't execute it.

wait_for_healthy() {
	local service="$1"
	local timeout="${2:-120}"
	local elapsed=0
	echo "Waiting for $service to be healthy..."
	while [ $elapsed -lt "$timeout" ]; do
		if docker compose ps --format json "$service" 2>/dev/null | grep -q '"healthy"'; then
			echo "$service is healthy."
			return 0
		fi
		sleep 2
		elapsed=$((elapsed + 2))
	done
	echo "Error: $service did not become healthy within ${timeout}s"
	exit 1
}

# Bring a service up so it reflects current compose state, then make sure it
# re-reads any mounted config files even if compose state was unchanged.
#
# `docker compose up --detach SERVICE` already recreates the container when
# the image, environment, or mount definitions have changed. But the contents
# of files inside a mounted volume (e.g. versatiles.yaml) are
# invisible to compose — when only file *content* changes, `up` is a no-op
# and the running container keeps using the stale config it read at startup.
#
# This helper detects whether `up` actually recreated the container (by
# comparing container IDs) and runs an extra fallback action if it didn't.
#
# Usage:
#   up_with_config_fallback <service> <fallback>
#   <fallback> ∈ { sighup, reload, restart }
#     sighup  → `docker compose kill -s SIGHUP SERVICE` (versatiles reloads its
#               -c config with no downtime: tile sources updated incrementally,
#               in-flight requests complete against the version they started with)
#     reload  → `docker compose exec SERVICE nginx -s reload` (graceful reload)
#     restart → `docker compose restart SERVICE`         (full restart, drops
#               in-flight connections — last resort)
up_with_config_fallback() {
	local service="$1"
	local fallback="$2"

	local before after
	before=$(docker compose ps -q "$service" 2>/dev/null || echo "")
	docker compose up --detach "$service"
	after=$(docker compose ps -q "$service" 2>/dev/null || echo "")

	if [ -z "$before" ] || [ "$before" != "$after" ]; then
		# Container was started or recreated — it already reads the latest config.
		echo "$service container recreated (compose state changed)."
		return 0
	fi

	# Container was unchanged at the compose level; force it to pick up new
	# file content from mounted volumes.
	case "$fallback" in
		sighup)
			echo "$service compose state unchanged — sending SIGHUP to reload config."
			docker compose kill -s SIGHUP "$service"
			;;
		reload)
			echo "$service compose state unchanged — re-rendering templates and reloading."
			nginx_render_and_reload
			;;
		restart)
			echo "$service compose state unchanged — restarting to re-read config."
			docker compose restart "$service"
			;;
		*)
			echo "Error: unknown fallback action '$fallback' (expected: sighup|reload|restart)"
			exit 1
			;;
	esac
}

# Re-render nginx's config templates inside the running container and reload.
#
# nginx renders /etc/nginx/templates/*.template into /etc/nginx/conf.d only once,
# at container startup (entrypoint: 10-compute-cache-size sets CACHE_MAX_SIZE_MB,
# then the image's 20-envsubst renders). A plain `nginx -s reload` re-reads the
# already-rendered conf, so edits to the *template* stay invisible until the
# container is recreated — hence re-running the render steps here, sourcing the
# cache-size envsh first so CACHE_MAX_SIZE_MB is defined.
#
# The reload itself is graceful: the master keeps serving through old workers
# until the new ones are up, so no connection is dropped. Requires a running
# nginx container.
nginx_render_and_reload() {
	docker compose exec -T nginx sh -c \
		'. /docker-entrypoint.d/10-compute-cache-size.envsh; /docker-entrypoint.d/20-envsubst-on-templates.sh && nginx -s reload'
}

# Apply nginx config changes without risking a container recreate.
#
# up_with_config_fallback() leads with `docker compose up --detach`, which
# recreates the container whenever compose-level state changed — most often a
# base image that `docker compose pull` just fetched. Recreating nginx unbinds
# :80/:443 for a moment: in-flight connections are dropped and new ones refused
# until the replacement is listening. That is an acceptable price on the tile
# update path, which is already reloading services; it is not one to pay on a
# run where nothing else happened and only the config needs applying.
#
# So reload in place instead. A pulled nginx image is simply left for the next
# run that goes through the full update path.
#
# If nginx is not running there is nothing to reload in place, so hand over to
# up_with_config_fallback, which starts it.
reload_nginx_in_place() {
	local cid
	cid=$(docker compose ps -q nginx 2>/dev/null || echo "")

	if [ -z "$cid" ] || [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo false)" != "true" ]; then
		echo "nginx is not running — bringing it up instead of reloading."
		up_with_config_fallback nginx reload
		return
	fi

	echo "Re-rendering nginx templates and reloading in place."
	nginx_render_and_reload
}
