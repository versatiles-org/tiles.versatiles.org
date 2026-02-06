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

# Ensure all services are up to date (only recreates containers whose config/image changed)
echo "Starting Docker Compose services..."
docker compose up --detach --build

# Force-recreate nginx to pick up bind-mounted file changes (e.g. nginx.conf)
# Single-file bind mounts track by inode; git pull creates new inodes.
echo "Recreating nginx container..."
docker compose up --detach --force-recreate nginx

# Clear cache data
echo "Clearing cache data..."
./bin/ramdisk/clear.sh

echo "Operations completed successfully."
