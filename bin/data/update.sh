#!/usr/bin/env bash

# This script downloads necessary tile data and frontend for VersaTiles.

# Navigate to the project's root directory relative to this script.
cd "$(dirname "$0")/../.."

# Load environment variables.
source .env

# Ensure the directory for Versatiles data exists.
mkdir -p volumes/versatiles

mkdir -p volumes/temp
rm -rf volumes/temp/*

function download {
    local URL=$1
    local FILENAME=$2
    
    if [ ! -f volumes/versatiles/osm.versatiles ]; then
        # Download OpenStreetMap data in Versatiles format.
        if [ -z "$BBOX" ]; then
            # Download the complete dataset if BBOX is not specified.
            echo "Downloading the complete planet data..."
            wget --progress=dot:giga "$URL" -O "volumes/versatiles/$FILENAME"
            mv "volumes/versatiles/$FILENAME" "volumes/versatiles/$FILENAME"
        else
            # Download only the specified BBOX area.
            echo "Downloading data for specified BBOX..."
            mkdir -p volumes/temp
            rm -rf volumes/temp/*
            docker run -v "$(pwd)/volumes/temp/:/data/:rw" versatiles/versatiles:latest-scratch versatiles convert --bbox "$BBOX" --bbox-border 3 "$URL" "/data/$FILENAME"
            mv "volumes/temp/$FILENAME" "volumes/versatiles/$FILENAME"
        fi
    fi
}

download https://download.versatiles.org/osm.versatiles osm.versatiles
download https://download.versatiles.org/hillshade-vectors.versatiles hillshade-vectors.versatiles

# Check for successful download and setup.
if [ ! -f volumes/versatiles/osm.versatiles ]; then
    echo "Failed to download or convert Versatiles data."
    exit 1
fi

if [ ! -f volumes/versatiles/frontend.br.tar ]; then
    # Download the frontend for the Versatiles application.
    echo "Downloading the frontend..."
    wget --no-verbose --progress=dot:giga "https://github.com/versatiles-org/versatiles-frontend/releases/latest/download/frontend.br.tar" -O volumes/versatiles/frontend.br.tar
fi

# Setup the frontend: Extract and apply necessary patches.
echo "Setting up the frontend..."
rm -rf volumes/versatiles/static
cp -r static volumes/versatiles/

echo "Setup completed successfully."
