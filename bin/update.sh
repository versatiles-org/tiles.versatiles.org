#!/usr/bin/env bash
set -euo pipefail

# Update script: pull latest code, rebuild, and do a rolling restart.

cd "$(dirname "$0")/.."
source bin/deploy/helpers.sh

# Update the repository with the latest changes from Git
echo "Updating repository from Git..."
git pull

# Build (ensure, fetch assets, pull/build images, download pipeline)
./bin/deploy/build.sh

# Recreate backend services first (nginx keeps serving with old backends)
echo "Updating backend services..."
docker compose up --detach versatiles
wait_for_healthy versatiles

# Recreate nginx last (backends are already up and healthy)
echo "Updating nginx..."
docker compose up --detach --force-recreate nginx
wait_for_healthy nginx

# Clear cache data
echo "Clearing cache data..."
./bin/ramdisk/clear.sh

# Verify deployment
echo ""
echo "Running verification..."
./bin/verify.sh

echo "Operations completed successfully."
