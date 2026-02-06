#!/usr/bin/env bash
set -euo pipefail

# This script downloads the frontend for VersaTiles, but only if a newer version is available.

# Navigate to the project's root directory relative to this script.
cd "$(dirname "$0")/../.."

# Ensure the directory for VersaTiles data exists.
mkdir -p volumes/versatiles

FRONTEND_FILE="volumes/versatiles/frontend.br.tar"
TAG_FILE="volumes/versatiles/frontend.version"

# Get the latest release tag via redirect (lightweight HEAD request, no body downloaded)
LATEST_TAG=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/versatiles-org/versatiles-frontend/releases/latest)
LATEST_TAG="${LATEST_TAG##*/}"

# Check if we already have this version
CURRENT_TAG=""
if [ -f "$TAG_FILE" ]; then
    CURRENT_TAG=$(cat "$TAG_FILE")
fi

if [ "$LATEST_TAG" = "$CURRENT_TAG" ] && [ -f "$FRONTEND_FILE" ]; then
    echo "Frontend is up to date ($CURRENT_TAG)"
    exit 0
fi

# Download frontend
echo "Downloading frontend $LATEST_TAG (was: ${CURRENT_TAG:-none})..."
curl -fLs "https://github.com/versatiles-org/versatiles-frontend/releases/download/$LATEST_TAG/frontend.br.tar.gz" | gzip -d >"$FRONTEND_FILE"
echo "$LATEST_TAG" >"$TAG_FILE"
echo "Frontend updated to $LATEST_TAG"
