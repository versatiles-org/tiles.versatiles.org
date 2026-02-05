#!/usr/bin/env bash
set -euo pipefail

# This script triggers the download pipeline update inside the download-updater container.

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."

echo "Running download pipeline update..."
docker compose exec download-updater npx tsx src/run_once.ts

echo "Reloading nginx to pick up new configuration..."
docker compose exec nginx nginx -s reload

echo "Download pipeline update completed successfully."
