#!/usr/bin/env bash
set -euo pipefail

# This script triggers the download pipeline update inside the download-updater container.

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."

echo "Building download-updater image..."
docker compose build download-updater

echo "Running tile data update..."
docker compose run --rm download-updater

echo "Restarting versatiles to pick up the new versatiles.yaml..."
docker compose restart versatiles

echo "Tile data update completed successfully."
