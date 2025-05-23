#!/usr/bin/env bash

# This script downloads necessary tile data for VersaTiles.

# Navigate to the project's root directory relative to this script.
cd "$(dirname "$0")/../.."

# Load environment variables.
source .env

# Ensure the directory for Versatiles data exists.
mkdir -p volumes/versatiles

function download {
    local URL="https://download.versatiles.org/${1}.versatiles"
    local FILENAME="volumes/versatiles/${1}.versatiles"

    mkdir -p volumes/temp
    rm -rf volumes/temp/*

    if [ ! -f "$FILENAME" ]; then
        # Download OpenStreetMap data in Versatiles format.
        if [ -z "$BBOX" ]; then
            # Download the complete dataset if BBOX is not specified.
            echo "Downloading the complete planet data..."
            wget --progress=dot:giga "$URL" -O "volumes/temp/temp.versatiles"
        else
            # Download only the specified BBOX area.
            echo "Downloading data for specified bbox..."
            docker run -v "$(pwd)/volumes/temp/:/data/:rw" versatiles/versatiles:latest-scratch versatiles convert --bbox "$BBOX" --bbox-border 3 "$URL" "/data/temp.versatiles"
        fi
        mv "volumes/temp/temp.versatiles" "$FILENAME"
    fi
}

download osm
download hillshade-vectors
download landcover-vectors
download bathymetry-vectors

# Check for successful download and setup.
if [ ! -f volumes/versatiles/osm.versatiles ]; then
    echo "Failed to download or convert VersaTiles data."
    exit 1
fi

echo "Setup completed successfully."
