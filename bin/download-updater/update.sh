#!/usr/bin/env bash
set -euo pipefail

# This script triggers the download pipeline update inside the download-updater container.

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."
source bin/deploy/helpers.sh

echo "Building download-updater image..."
docker compose build download-updater

echo "Running tile data update..."
docker compose run --rm download-updater

# Pick up the new versatiles.yaml: recreate only if compose state changed,
# otherwise SIGHUP so versatiles reloads the config with no downtime.
echo "Reloading versatiles to pick up the new versatiles.yaml..."
up_with_config_fallback versatiles sighup
wait_for_healthy versatiles

echo "Tile data update completed successfully."
