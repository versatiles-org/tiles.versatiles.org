#!/usr/bin/env bash
set -euo pipefail

# This script clears the cache directory.

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."

# Remove all files in the cache directory safely, ensuring the path is not empty to avoid dangerous deletions
if [ -d "./volumes/cache" ]; then
    echo "Clearing cache..."
    rm -rf ./volumes/cache/*
    echo "Cache cleared successfully."
else
    echo "Cache directory not found."
fi
