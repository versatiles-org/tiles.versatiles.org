#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

check_map_data() {
    FILENAME=$1

    # Paths for local and remote md5 URLs
    HASH_FILE="/versatiles/data/$FILENAME.md5"
    DATA_FILE="/versatiles/data/$FILENAME"
    REMOTE_HASH_URL="https://download.versatiles.org/$FILENAME.md5"

    # Check if the local md5 file exists
    if [ -f "$HASH_FILE" ]; then
        # Read the contents of the local MD5 file into a variable
        LOCAL_HASH=$(cat "$HASH_FILE")
        
        # Download the remote MD5 file contents directly into a variable
        REMOTE_HASH=$(wget -qO- "$REMOTE_HASH_URL")

        # Compare the local and remote MD5 contents
        if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
            echo "$FILENAME: MD5 mismatch, downloading ..."
        else
            echo "$FILENAME: MD5 files match, no need to download."
            return 0
        fi
    else
        # If no local MD5 file, download the latest files
        echo "$FILENAME: No local MD5 found, downloading ..."
    fi

    # Download the data and MD5 files
    wget -q --show-progress --progress=dot:giga -O "$DATA_FILE" -L "https://download.versatiles.org/$FILENAME"
    wget -q --show-progress --progress=dot:giga -O "$HASH_FILE" -L "$REMOTE_HASH_URL"
}

# Call check_map_data for each dataset
check_map_data osm.versatiles
#check_map_data hillshade-vectors.versatiles
check_map_data landcover-vectors.versatiles
