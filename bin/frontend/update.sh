#!/usr/bin/env bash
set -euo pipefail

# This script downloads the frontend for VersaTiles, but only if a newer version is available.
#
# Exit codes:
#   0  → frontend already up to date (no download)
#   10 → frontend was downloaded/updated (the caller must replace the tile
#        server container, which reads the tar only at startup, and clear the
#        nginx cache — otherwise the old frontend keeps being served)

# Navigate to the project's root directory relative to this script.
cd "$(dirname "$0")/../.."

# Ensure the directory for frontend data exists.
mkdir -p volumes/frontend

FRONTEND_FILE="volumes/frontend/frontend.br.tar"
TAG_FILE="volumes/frontend/frontend.version"

# Get the latest release tag via redirect (lightweight HEAD request, no body downloaded)
LATEST_TAG=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/versatiles-org/versatiles-frontend/releases/latest)
LATEST_TAG="${LATEST_TAG##*/}"

# Without a real tag there is nothing to download: the redirect ends at
# ".../releases/latest" itself (or ".../releases") when it could not be resolved.
case "$LATEST_TAG" in
    ""|latest|releases)
        echo "Error: could not determine the latest frontend release tag." >&2
        exit 1
        ;;
esac

# Check if we already have this version
CURRENT_TAG=""
if [ -f "$TAG_FILE" ]; then
    CURRENT_TAG=$(cat "$TAG_FILE")
fi

if [ "$LATEST_TAG" = "$CURRENT_TAG" ] && [ -f "$FRONTEND_FILE" ]; then
    echo "Frontend is up to date ($CURRENT_TAG)"
    exit 0
fi

echo "Downloading frontend $LATEST_TAG (was: ${CURRENT_TAG:-none})..."

# Download to a temp file and move it into place only once it is complete. The
# tile server reads this tar at every start, so the old one must survive a failed
# download: a truncated tar keeps the server from starting at all, and an empty
# one makes it serve nothing. `>` would truncate the live file before the first
# byte arrives.
TMP_FILE="$FRONTEND_FILE.tmp"
trap 'rm -f "$TMP_FILE"' EXIT
# pipefail: a failed curl or an incomplete gzip stream aborts here.
curl -fLsS "https://github.com/versatiles-org/versatiles-frontend/releases/download/$LATEST_TAG/frontend.br.tar.gz" | gzip -d >"$TMP_FILE"
# Must be a complete, readable tar.
tar -tf "$TMP_FILE" >/dev/null
mv "$TMP_FILE" "$FRONTEND_FILE"
echo "$LATEST_TAG" >"$TAG_FILE"
echo "Frontend updated to $LATEST_TAG"

# Signal to the caller that the frontend changed: the tile server container
# must be replaced and the cache cleared.
exit 10
