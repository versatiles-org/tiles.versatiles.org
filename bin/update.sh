#!/usr/bin/env bash
set -euo pipefail

# This script performs a series of setup operations for a project:
# - Pulls latest updates from Git
# - Updates data using a custom script
# - Updates download pipeline
# - Clears cached data
# - Restarts Docker Compose services

# Navigate to the project's parent directory
cd "$(dirname "$0")/.."

# Update the repository with the latest changes from Git
echo "Updating repository from Git..."
git pull

# Update frontend
echo "Fetching frontend..."
./bin/frontend/update.sh

# Update data using a custom script
echo "Fetching data..."
./bin/data/update.sh

# test NGINX
docker exec nginx sh -c "/docker-entrypoint.d/20-envsubst-on-templates.sh; nginx -t"

# Clear cache data using a custom script
echo "Clearing cache data..."
./bin/ramdisk/clear.sh

# Restart Docker Compose services with force recreation to ensure a clean state
echo "Restarting Docker Compose services..."
docker compose pull
docker compose up --detach --force-recreate --build

# Update download pipeline
echo "Updating download pipeline..."
./bin/download/update.sh

echo "Operations completed successfully."
