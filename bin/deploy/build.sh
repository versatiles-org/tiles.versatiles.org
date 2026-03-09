#!/usr/bin/env bash
set -euo pipefail

# Shared build steps: ensure infrastructure, fetch assets, pull/build images, run download pipeline.
# Called by setup.sh and update.sh.

cd "$(dirname "$0")/../.."

# Ensure infrastructure (volumes, RAM disk, cron jobs)
./bin/deploy/ensure.sh

# Fetch frontend
echo "Fetching frontend..."
./bin/frontend/update.sh

# Fetch styles
echo "Fetching styles..."
./bin/styles/update.sh

# Pull Docker images
echo "Pulling Docker images..."
docker compose pull

# Build custom images
echo "Building Docker images..."
docker compose build download-updater

# Run download pipeline
echo "Running download pipeline..."
docker compose run --rm download-updater
