#!/usr/bin/env bash
set -euo pipefail

# This script mounts the remote storage via SSHFS for accessing versioned .versatiles files.

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."

# Load environment variables from the .env file
source .env

# Ensure the mount point exists
mkdir -p "./volumes/download/remote_files"

# Check if already mounted
if mountpoint -q "./volumes/download/remote_files"; then
    echo "Remote storage is already mounted."
    exit 0
fi

echo "Mounting remote storage via SSHFS..."
sshfs -o IdentityFile="./.ssh/storage" \
      -o reconnect \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=3 \
      -o port=23 \
      "${STORAGE_URL}:/home" \
      "./volumes/download/remote_files"

echo "Remote storage mounted successfully."
