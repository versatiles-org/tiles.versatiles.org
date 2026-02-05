#!/usr/bin/env bash
set -euo pipefail

# This script downloads necessary tile data for VersaTiles from the storage box.

# Navigate to the project's root directory relative to this script.
cd "$(dirname "$0")/../.."

# Load environment variables.
source .env

# Ensure the directory for VersaTiles data exists.
mkdir -p volumes/versatiles
mkdir -p volumes/temp

# Extract WebDAV credentials from STORAGE_URL
WEBDAV_USER=$(echo "${STORAGE_URL}" | cut -d@ -f1)
WEBDAV_HOST=$(echo "${STORAGE_URL}" | cut -d@ -f2)

echo "Updating VersaTiles data from storage box..."

function get_latest_file {
    local FOLDER="$1"
    # List files via SSH and get the latest .versatiles file (sorted by name, last one)
    ssh -i .ssh/storage -p 23 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "${STORAGE_URL}" "ls -1 /home/${FOLDER}/*.versatiles 2>/dev/null" | sort | tail -1
}

function download {
    local FOLDER="$1"
    local NAME="$1.versatiles"

    echo "Checking ${NAME}..."

    # Get the latest file path from storage
    local REMOTE_PATH
    REMOTE_PATH=$(get_latest_file "$FOLDER")

    if [ -z "$REMOTE_PATH" ]; then
        echo "  Warning: No .versatiles file found in ${FOLDER}/, skipping"
        return
    fi

    local REMOTE_FILENAME
    REMOTE_FILENAME=$(basename "$REMOTE_PATH")

    # Get remote MD5 via SSH
    local MD5_REMOTE
    MD5_REMOTE=$(ssh -i .ssh/storage -p 23 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "${STORAGE_URL}" "cat '${REMOTE_PATH}.md5' 2>/dev/null || md5sum '${REMOTE_PATH}'" | awk '{print $1}')

    # Get local MD5 if exists
    local MD5_LOCAL
    MD5_LOCAL=$(cat "volumes/versatiles/${NAME}.md5" 2>/dev/null | awk '{print $1}' || echo "")

    if [ -f "volumes/versatiles/${NAME}" ] && [ "$MD5_LOCAL" = "$MD5_REMOTE" ]; then
        echo "  Up-to-date, skipping"
        return
    fi

    echo "  Downloading ${REMOTE_FILENAME}..."

    if [ -z "${BBOX:-}" ]; then
        # Download full file via SCP
        scp -i .ssh/storage -P 23 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "${STORAGE_URL}:${REMOTE_PATH}" "volumes/temp/${NAME}"
    else
        # Download with bbox filter via VersaTiles using WebDAV URL
        local WEBDAV_URL="https://${WEBDAV_USER}:${STORAGE_PASS}@${WEBDAV_HOST}${REMOTE_PATH#/home}"
        echo "  Applying bbox filter: ${BBOX}"
        docker run --rm -v "$(pwd)/volumes/temp/:/data/:rw" versatiles/versatiles:latest-scratch \
            versatiles convert --bbox "$BBOX" --bbox-border 3 "$WEBDAV_URL" "/data/${NAME}"
    fi

    # Save MD5
    echo "${MD5_REMOTE} ${NAME}" > "volumes/temp/${NAME}.md5"
    echo "  Done"
}

# Clean temp directory
rm -rf volumes/temp/*

# Download required datasets
download osm
download hillshade-vectors
download landcover-vectors
download bathymetry-vectors

# Move downloaded files to the final directory
mv volumes/temp/* volumes/versatiles/ 2>/dev/null || true
rm -rf volumes/temp

# Check for successful download
if [ ! -f volumes/versatiles/osm.versatiles ]; then
    echo "Error: osm.versatiles not found after update" >&2
    exit 1
fi

echo "Update completed successfully."
