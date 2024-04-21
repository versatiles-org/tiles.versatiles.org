#!/usr/bin/env bash

# This script clears the cache directory and reloads the nginx server using Docker Compose.

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."

# Load environment variables from the .env file
source .env

# Remove all files in the cache directory safely, ensuring the path is not empty to avoid dangerous deletions
if [ -d "./volumes/cache" ]; then
    echo "Clearing cache..."
    rm -rf ./volumes/cache/*
else
    echo "Cache directory not found."
fi

# Reload nginx to apply any configuration changes
echo "Reloading nginx..."
docker compose exec nginx nginx -s reload

# Check if the nginx reload command succeeded
if [ $? -ne 0 ]; then
    echo "Failed to reload nginx. Please check the configuration."
    exit 1
fi

echo "Nginx has been reloaded successfully."
