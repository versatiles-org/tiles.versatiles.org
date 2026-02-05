#!/usr/bin/env bash
set -euo pipefail

# This script downloads the frontend for VersaTiles.

# Navigate to the project's root directory relative to this script.
cd "$(dirname "$0")/../.."

# Ensure the directory for VersaTiles data exists.
mkdir -p volumes/versatiles

# Download frontend
curl -fLs https://github.com/versatiles-org/versatiles-frontend/releases/latest/download/frontend.br.tar.gz | gzip -d >"volumes/versatiles/frontend.br.tar"
