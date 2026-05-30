#!/usr/bin/env bash
set -euo pipefail

# Shared build steps: ensure infrastructure, fetch assets, pull/build images.
# Called by setup.sh and update.sh.
#
# This script does NOT run the download pipeline — that is owned by:
#   - setup.sh   for the initial population on a fresh server
#   - update.sh  for ongoing prepare/finalize updates
#
# Exit codes:
#   0  → success, no frontend/styles change
#   10 → success, frontend and/or styles were updated. These assets are served
#        by the versatiles container from a tar it loads at startup and are
#        cached by nginx, so the caller must restart versatiles and clear the
#        cache for the new assets to actually reach clients. update.sh relies on
#        this signal to do that even when no tile data changed.
#   other non-zero → a build step failed (propagated as-is).

cd "$(dirname "$0")/../.."

# Track whether any frontend/styles asset was refreshed. The asset scripts exit
# 10 when they downloaded a new version; any other non-zero exit is a real error.
ASSETS_CHANGED=false

run_asset_update() {
	local label="$1"; shift
	local rc=0
	set +e
	"$@"
	rc=$?
	set -e
	case $rc in
		0) ;;                       # up to date
		10) ASSETS_CHANGED=true ;;  # downloaded a new version
		*) echo "ERROR: $label failed (exit $rc)."; exit $rc ;;
	esac
}

# Ensure infrastructure (volumes, RAM disk, cron jobs)
./bin/deploy/ensure.sh

# Fetch frontend
echo "Fetching frontend..."
run_asset_update "frontend update" ./bin/frontend/update.sh

# Fetch styles
echo "Fetching styles..."
run_asset_update "styles update" ./bin/styles/update.sh

# Pull Docker images
echo "Pulling Docker images..."
docker compose pull

# Build custom images
echo "Building Docker images..."
docker compose build download-updater

# Propagate the asset-changed signal so the caller can restart + clear cache.
if [ "$ASSETS_CHANGED" = "true" ]; then
	echo "Frontend and/or styles changed — caller must restart versatiles and clear the cache."
	exit 10
fi
