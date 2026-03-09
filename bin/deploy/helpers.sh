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
