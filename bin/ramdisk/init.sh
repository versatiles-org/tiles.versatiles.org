#!/usr/bin/env bash
set -euo pipefail

# This script configures a RAM disk for caching by updating /etc/fstab and mounting it.

# Navigate to the root directory of the project relative to the script location.
cd "$(dirname "$0")/../.."

# Load environment variables from the .env file
source .env

# Create the cache directory if it doesn't already exist.
mkdir -p volumes/cache

# Check if already mounted
if mountpoint -q "./volumes/cache"; then
    echo "RAM disk is already mounted."
    exit 0
fi

# Validate that RAM_DISK_GB is set and is a numeric value
if ! [[ "$RAM_DISK_GB" =~ ^[0-9]+$ ]]; then
    echo "Error: RAM_DISK_GB is not set or not a valid number."
    exit 1
fi

CACHE_PATH="$(pwd)/volumes/cache"
FSTAB_ENTRY="ramdisk ${CACHE_PATH}/ tmpfs defaults,size=${RAM_DISK_GB}G,x-gvfs-show 0 0"

# Check if entry already exists in /etc/fstab
if grep -q "${CACHE_PATH}" /etc/fstab 2>/dev/null; then
    echo "RAM disk entry already exists in /etc/fstab"
else
    echo "Adding RAM disk configuration to /etc/fstab..."
    echo "${FSTAB_ENTRY}" >> /etc/fstab
fi

# Reload the systemd daemon to apply changes to fstab
echo "Reloading systemd daemon..."
systemctl daemon-reload

# Mount the newly configured RAM disk
echo "Mounting the RAM disk..."
mount volumes/cache

echo "RAM disk configured and mounted successfully."
