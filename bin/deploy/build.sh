#!/usr/bin/env bash
set -euo pipefail

# Shared build steps: ensure infrastructure, fetch assets, pull/build images.
# Called by setup.sh and update.sh.
#
# This script does NOT run the download pipeline — that is owned by:
#   - setup.sh   for the initial population on a fresh server
#   - update.sh  for ongoing prepare/finalize updates

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
