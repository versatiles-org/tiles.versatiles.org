#!/usr/bin/env bash
set -euo pipefail

# This script automates the setup of a system, including preparation of certificates,
# RAM disk initialization, data updates, and Docker operations.

# Move to the project's root directory relative to the script's location
cd "$(dirname "$0")/.."

# Persist maximum socket connections setting across reboots
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-versatiles.conf
sysctl -p /etc/sysctl.d/99-versatiles.conf

# Create a necessary directory for storing volumes
mkdir -p volumes

# Prepare SSL/TLS dummy certificates
echo "Preparing certificates..."
./bin/cert/create_dummy.sh

# Initialize RAM disk for better performance
echo "Initializing RAM disk..."
./bin/ramdisk/init.sh

# Update frontend
echo "Fetching frontend..."
./bin/frontend/update.sh

# Fetch or update necessary data
echo "Fetching data..."
./bin/data/update.sh

# Start Docker Compose services with force recreate to ensure clean setup
echo "Starting Docker Compose..."
docker compose up --detach --force-recreate

# Initialize Let's Encrypt valid certificates
echo "Initializing Let's Encrypt certificates..."
./bin/cert/create_valid.sh

echo "System setup completed successfully."
