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

# Pull latest images (old containers keep serving traffic)
echo "Pulling latest Docker images..."
docker compose pull

# Build all custom images (old containers keep serving traffic)
echo "Building Docker images..."
docker compose build

# Start download-updater with new image and run download task
echo "Starting download-updater and fetching data..."
docker compose up --detach --force-recreate download-updater
docker compose exec download-updater npx tsx src/run_once.ts

# Recreate all containers at once (minimal downtime, images are already built/pulled)
echo "Recreating all Docker Compose services..."
docker compose up --detach --force-recreate

# Clear cache data
echo "Clearing cache data..."
./bin/ramdisk/clear.sh

echo "Operations completed successfully."
