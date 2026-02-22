#!/usr/bin/env bash
set -euo pipefail

# This script downloads the styles for VersaTiles, but only if a newer version is available.

# Navigate to the project's root directory relative to this script.
cd "$(dirname "$0")/../.."

# Ensure the directory for frontend data exists.
mkdir -p volumes/frontend

STYLES_FILE="volumes/frontend/styles.tar"
TAG_FILE="volumes/frontend/styles.version"

# Get the latest release tag via redirect (lightweight HEAD request, no body downloaded)
LATEST_TAG=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/versatiles-org/versatiles-style/releases/latest)
LATEST_TAG="${LATEST_TAG##*/}"

# Check if we already have this version
CURRENT_TAG=""
if [ -f "$TAG_FILE" ]; then
    CURRENT_TAG=$(cat "$TAG_FILE")
fi

if [ "$LATEST_TAG" = "$CURRENT_TAG" ] && [ -f "$STYLES_FILE" ]; then
    echo "Styles are up to date ($CURRENT_TAG)"
    exit 0
fi

# Download styles
echo "Downloading styles $LATEST_TAG (was: ${CURRENT_TAG:-none})..."
curl -fLs "https://github.com/versatiles-org/versatiles-style/releases/download/$LATEST_TAG/styles.tar.gz" | gzip -d >"$STYLES_FILE"
echo "$LATEST_TAG" >"$TAG_FILE"
echo "Styles updated to $LATEST_TAG"
