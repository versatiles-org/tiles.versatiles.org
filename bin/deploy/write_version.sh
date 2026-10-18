#!/usr/bin/env bash
set -euo pipefail

# Writes volumes/static/version.json, which nginx serves as /version.json
# (see `location = /version.json` in nginx/templates/proxy.conf.template):
#
#   {
#     "versatiles": "5.1.0",      tile server, asked via `versatiles --version`
#                                 in the running container (null if not running)
#     "frontend":   "v3.16.1",    release tag fetched by bin/frontend/update.sh
#     "styles":     "v6.2.0",     release tag fetched by bin/styles/update.sh
#     "updated":    "2026-10-19T08:00:00Z"
#   }
#
# Called at the end of update.sh, setup.sh and restart.sh — after the tile
# server container has been replaced, so the version is the one now serving.
# Written to a temp file and renamed, so a reader never sees a partial file,
# and the mtime moves, so browsers revalidating via Last-Modified get the new
# content.

cd "$(dirname "$0")/../.."

read_tag() {
	if [ -f "$1" ]; then
		printf '"%s"' "$(tr -d '[:space:]' <"$1")"
	else
		printf 'null'
	fi
}

versatiles_version() {
	local out
	# `versatiles 5.1.0` → `5.1.0`. Empty when no container is running.
	out=$(docker compose exec -T versatiles versatiles --version 2>/dev/null | awk 'NR==1 {print $2}' || true)
	if [ -n "$out" ]; then
		printf '"%s"' "$out"
	else
		printf 'null'
	fi
}

mkdir -p volumes/static
TMP=$(mktemp volumes/static/.version.json.XXXXXX)
cat >"$TMP" <<JSON
{
  "versatiles": $(versatiles_version),
  "frontend": $(read_tag volumes/frontend/frontend.version),
  "styles": $(read_tag volumes/frontend/styles.version),
  "updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
chmod 644 "$TMP"
mv "$TMP" volumes/static/version.json
echo "Wrote volumes/static/version.json"
