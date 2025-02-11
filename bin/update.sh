#!/usr/bin/env bash

# This script performs a series of setup operations for a project:
# - Pulls latest updates from Git
# - Updates data using a custom script
# - Clears cached data
# - Restarts Docker Compose services

# Navigate to the project's parent directory
cd "$(dirname "$0")/.."

# Update the repository with the latest changes from Git
echo "Updating repository from Git..."
git pull
if [ $? -ne 0 ]; then
    echo "Failed to pull updates from Git. Exiting."
    exit 1
fi

# Update frontend
echo "Fetching frontend..."
./bin/frontend/update.sh
if [ $? -ne 0 ]; then
    echo "Failed to update frontend. Exiting."
    exit 1
fi

# Update data using a custom script
echo "Fetching data..."
./bin/data/update.sh
if [ $? -ne 0 ]; then
    echo "Failed to update data. Exiting."
    exit 1
fi

# test NGINX
docker exec -it nginx sh -c "/docker-entrypoint.d/20-envsubst-on-templates.sh; nginx -t"
if [ $? -ne 0 ]; then
    echo "NGINX conf test failed. Exiting."
    exit 1
fi

# Clear cache data using a custom script
echo "Clearing cache data..."
./bin/ramdisk/clear.sh
if [ $? -ne 0 ]; then
    echo "Failed to clear cache data. Exiting."
    exit 1
fi

# Restart Docker Compose services with force recreation to ensure a clean state
echo "Restarting Docker Compose services..."
docker compose pull
docker compose up --detach --force-recreate --build
if [ $? -ne 0 ]; then
    echo "Failed to restart Docker Compose services. Exiting."
    exit 1
fi

echo "Operations completed successfully."
