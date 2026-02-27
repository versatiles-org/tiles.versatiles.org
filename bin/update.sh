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

wait_for_healthy() {
	local service="$1"
	local timeout="${2:-120}"
	local elapsed=0
	echo "Waiting for $service to be healthy..."
	while [ $elapsed -lt "$timeout" ]; do
		if docker compose ps --format json "$service" 2>/dev/null | grep -q '"healthy"'; then
			echo "$service is healthy."
			return 0
		fi
		sleep 2
		elapsed=$((elapsed + 2))
	done
	echo "Error: $service did not become healthy within ${timeout}s"
	exit 1
}

# Update the repository with the latest changes from Git
echo "Updating repository from Git..."
git pull

# Update frontend
echo "Fetching frontend..."
./bin/frontend/update.sh

# Update styles
echo "Fetching styles..."
./bin/styles/update.sh

# Pull latest images (old containers keep serving traffic)
echo "Pulling latest Docker images..."
docker compose pull

# Build all custom images (old containers keep serving traffic)
echo "Building Docker images..."
docker compose build
docker compose build download-updater

# Recreate backend services first (nginx keeps serving with old backends)
echo "Updating backend services..."
docker compose up --detach versatiles
wait_for_healthy versatiles

# Run download pipeline to fetch latest data
echo "Fetching data..."
docker compose run --rm download-updater

# Recreate nginx last (backends are already up and healthy)
echo "Updating nginx..."
docker compose up --detach nginx
wait_for_healthy nginx
docker compose exec nginx nginx -s reload

# Clear cache data
echo "Clearing cache data..."
./bin/ramdisk/clear.sh

# Verify deployment
echo ""
echo "Running verification..."
./bin/verify.sh

echo "Operations completed successfully."
