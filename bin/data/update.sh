#!/usr/bin/env bash
set -euo pipefail

# This script downloads necessary tile data for VersaTiles.

# Navigate to the project's root directory relative to this script.
cd "$(dirname "$0")/../.."

# Load environment variables.
source .env

# Ensure the directory for VersaTiles data exists.
mkdir -p volumes/versatiles

function download {
    local NAME="$1.versatiles"
    local URL="https://download.versatiles.org/${NAME}"

    local MD5_LOCAL=$(cat "volumes/versatiles/${NAME}.md5" 2>/dev/null || echo "")
    local MD5_REMOTE_URL=$(curl -sf "${URL}.md5" || { echo "Failed to fetch MD5 for ${NAME}" >&2; exit 1; })

    if [ ! -f "volumes/versatiles/${NAME}" ] || [ "$MD5_LOCAL" != "$MD5_REMOTE_URL" ]; then
        # Download OpenStreetMap data in VersaTiles format.
        if [ -z "${BBOX:-}" ]; then
            # Download the complete dataset if BBOX is not specified.
            echo "Downloading the complete planet data..."
            wget -q "$URL" -O "volumes/temp/${NAME}"
        else
            # Download only the specified BBOX area.
            echo "Downloading data for specified bbox..."
            docker run --rm -v "$(pwd)/volumes/temp/:/data/:rw" versatiles/versatiles:latest-scratch versatiles convert --bbox "$BBOX" --bbox-border 3 "$URL" "/data/${NAME}"
        fi
        wget -q "${URL}.md5" -O "volumes/temp/${NAME}.md5"
    fi
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
    echo "Failed to download or convert VersaTiles data."
    exit 1
fi

echo "Setup completed successfully."
