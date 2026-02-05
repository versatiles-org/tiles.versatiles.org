#!/usr/bin/env bash
set -euo pipefail

# This script automates the setup of a system, including preparation of certificates,
# RAM disk initialization, data updates, and Docker operations.

# Move to the project's root directory relative to the script's location
cd "$(dirname "$0")/.."

# Load environment variables from the .env file
source .env

# Persist maximum socket connections setting across reboots
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-versatiles.conf
sysctl -p /etc/sysctl.d/99-versatiles.conf

# Create necessary directories for storing volumes
echo "Creating volume directories..."
mkdir -p volumes/download/remote_files
mkdir -p volumes/download/local_files
mkdir -p volumes/download/nginx_conf
mkdir -p volumes/versatiles
mkdir -p volumes/cache
mkdir -p volumes/certbot-cert
mkdir -p volumes/certbot-www
mkdir -p volumes/nginx-cert
mkdir -p volumes/nginx-log

# Mount remote storage via SSHFS
echo "Mounting remote storage..."
./bin/sshfs/mount.sh

# Prepare SSL/TLS dummy certificates for both domains
echo "Preparing dummy certificates..."
./bin/cert/create_dummy.sh "${DOMAIN_NAME}"
./bin/cert/create_dummy.sh "${DOWNLOAD_DOMAIN}"

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
docker compose up --detach --force-recreate --build

# Run download pipeline to generate initial nginx config
echo "Running download pipeline..."
./bin/download/update.sh

# Initialize Let's Encrypt valid certificates for both domains
echo "Initializing Let's Encrypt certificates..."
./bin/cert/create_valid.sh "${DOMAIN_NAME}"
./bin/cert/create_valid.sh "${DOWNLOAD_DOMAIN}"

echo "System setup completed successfully."
