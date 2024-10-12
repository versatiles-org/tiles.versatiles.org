#!/usr/bin/env bash

# This script automates the setup of a system, including preparation of certificates,
# RAM disk initialization, data updates, and Docker operations.

# Move to the project's root directory relative to the script's location
cd "$(dirname "$0")/.."

# Increase maximum socket connections
sysctl -w vm.max_map_count=262144

# Create a necessary directory for storing volumes
mkdir -p volumes

# Prepare SSL/TLS dummy certificates
echo "Preparing certificates..."
./bin/cert/create_dummy.sh
if [ $? -ne 0 ]; then
    echo "Failed to create dummy certificates."
    exit 1
fi

# Initialize RAM disk for better performance
echo "Initializing RAM disk..."
./bin/ramdisk/init.sh
if [ $? -ne 0 ]; then
    echo "Failed to initialize RAM disk."
    exit 1
fi

# Fetch or update necessary data
echo "Fetching data..."
./bin/data/update.sh
if [ $? -ne 0 ]; then
    echo "Failed to fetch data."
    exit 1
fi

# Start Docker Compose services with force recreate to ensure clean setup
echo "Starting Docker Compose..."
docker compose up --detach --force-recreate
if [ $? -ne 0 ]; then
    echo "Failed to start Docker Compose."
    exit 1
fi

# Initialize Let's Encrypt valid certificates
echo "Initializing Let's Encrypt certificates..."
./bin/cert/create_valid.sh
if [ $? -ne 0 ]; then
    echo "Failed to create valid certificates."
    exit 1
fi

echo "System setup completed successfully."
