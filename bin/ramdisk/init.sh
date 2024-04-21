#!/usr/bin/env bash

# This script configures a RAM disk for caching by updating /etc/fstab and mounting it.

# Navigate to the root directory of the project relative to the script location.
cd "$(dirname "$0")/../.."

# Load environment variables from the .env file
source .env

# Create the cache directory if it doesn't already exist.
mkdir -p volumes/cache

# Validate that RAM_DISK_GB is set and is a numeric value
if ! [[ "$RAM_DISK_GB" =~ ^[0-9]+$ ]]; then
    echo "Error: RAM_DISK_GB is not set or not a valid number."
    exit 1
fi

# Append a new line to /etc/fstab to set up the RAM disk.
# This line configures a tmpfs mount point at the specified cache directory.
echo "Adding RAM disk configuration to /etc/fstab..."
echo "ramdisk $(pwd)/volumes/cache/ tmpfs defaults,size=${RAM_DISK_GB}G,x-gvfs-show 0 0" >> /etc/fstab

# Reload the systemd daemon to apply changes to fstab
echo "Reloading systemd daemon..."
systemctl daemon-reload
if [ $? -ne 0 ]; then
    echo "Failed to reload the systemd daemon."
    exit 1
fi

# Mount the newly configured RAM disk
echo "Mounting the RAM disk..."
mount volumes/cache
if [ $? -ne 0 ]; then
    echo "Failed to mount the RAM disk."
    exit 1
fi

echo "RAM disk configured and mounted successfully."
