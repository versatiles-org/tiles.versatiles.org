#!/usr/bin/env bash
set -euo pipefail

# This script performs a series of setup operations for a project:
# - Pulls latest updates from Git
# - Updates frontend
# - Runs download pipeline to fetch latest data
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

# Pull latest images
echo "Pulling latest Docker images..."
docker compose pull

# Build and start download-updater first to download data
echo "Starting download-updater and fetching data..."
docker compose up --detach --build download-updater
docker compose exec download-updater npx tsx src/run_once.ts

# Test NGINX config if nginx is running
if docker ps --format '{{.Names}}' | grep -q '^nginx$'; then
    docker exec nginx sh -c "/docker-entrypoint.d/20-envsubst-on-templates.sh; nginx -t"
fi

# Clear cache data
echo "Clearing cache data..."
./bin/ramdisk/clear.sh

# Start all Docker Compose services
echo "Starting Docker Compose services..."
docker compose up --detach --force-recreate --build

# Wait for nginx to be healthy before reloading
echo "Waiting for nginx to be ready..."
for _ in {1..30}; do
    if docker compose exec nginx nginx -t &>/dev/null; then
        echo "Reloading nginx..."
        docker compose exec nginx nginx -s reload
        break
    fi
    sleep 1
done

echo "Operations completed successfully."
