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
# of files inside a mounted volume (versatiles.yaml, download.conf) are
# invisible to compose — when only file *content* changes, `up` is a no-op
# and the running container keeps using the stale config it read at startup.
#
# This helper detects whether `up` actually recreated the container (by
# comparing container IDs) and runs an extra fallback action if it didn't.
#
# Usage:
#   up_with_config_fallback <service> <fallback>
#   <fallback> ∈ { restart, reload }
#     restart → `docker compose restart SERVICE`         (re-read mounted files)
#     reload  → `docker compose exec SERVICE nginx -s reload` (graceful reload)
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
		restart)
			echo "$service compose state unchanged — restarting to re-read config."
			docker compose restart "$service"
			;;
		reload)
			echo "$service compose state unchanged — sending nginx reload signal."
			docker compose exec -T "$service" nginx -s reload
			;;
		*)
			echo "Error: unknown fallback action '$fallback' (expected: restart|reload)"
			exit 1
			;;
	esac
}
