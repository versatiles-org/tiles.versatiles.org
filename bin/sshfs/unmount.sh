#!/usr/bin/env bash
set -euo pipefail

# This script unmounts the remote storage SSHFS mount.

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."

# Check if mounted
if ! mountpoint -q "./volumes/download/remote_files"; then
    echo "Remote storage is not mounted."
    exit 0
fi

echo "Unmounting remote storage..."
fusermount -u "./volumes/download/remote_files" || umount "./volumes/download/remote_files"

echo "Remote storage unmounted successfully."
