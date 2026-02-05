#!/usr/bin/env bash
set -euo pipefail

# This script downloads necessary tile data for VersaTiles.

# Navigate to the project's root directory relative to this script.
cd "$(dirname "$0")/../.."

# Load environment variables.
source .env

# Ensure the directory for VersaTiles data exists.
mkdir -p volumes/versatiles

echo "Updating VersaTiles data..."

function download {
    local NAME="$1.versatiles"
    local URL="https://download.versatiles.org/${NAME}"

    echo "Checking ${NAME}..."

    local MD5_LOCAL
    MD5_LOCAL=$(cat "volumes/versatiles/${NAME}.md5" 2>/dev/null || echo "")
    local MD5_REMOTE
    MD5_REMOTE=$(curl -sf "${URL}.md5" | tr -d ' \n\r') || {
        echo "  Error: Failed to fetch MD5 checksum" >&2
        exit 1
    }

    if [ -f "volumes/versatiles/${NAME}" ] && [ "$MD5_LOCAL" = "$MD5_REMOTE" ]; then
        echo "  Up-to-date, skipping"
        return
    fi

    if [ -z "${BBOX:-}" ]; then
        echo "  Downloading full dataset..."
        wget -q "$URL" -O "volumes/temp/${NAME}"
    else
        echo "  Downloading with bbox filter..."
        docker run --rm -v "$(pwd)/volumes/temp/:/data/:rw" versatiles/versatiles:latest-scratch versatiles convert --bbox "$BBOX" --bbox-border 3 "$URL" "/data/${NAME}"
    fi
    wget -q "${URL}.md5" -O "volumes/temp/${NAME}.md5"
    echo "  Done"
}

# Prepare a temporary directory for downloads.
mkdir -p volumes/temp
rm -rf volumes/temp/*

# Download required datasets.
download osm
download hillshade-vectors
download landcover-vectors
download bathymetry-vectors

# Move downloaded files to the final directory.
mv volumes/temp/* volumes/versatiles/ 2>/dev/null || true
rm -rf volumes/temp

# Check for successful download and setup.
if [ ! -f volumes/versatiles/osm.versatiles ]; then
    echo "Error: osm.versatiles not found after update" >&2
    exit 1
fi

echo "Update completed successfully."
