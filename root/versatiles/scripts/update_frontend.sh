#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

FRONTEND_TAR="/versatiles/data/frontend.br.tar"
if [ ! -f "$FRONTEND_TAR" ]; then
    echo "frontend.br.tar not found, downloading..."
    wget -q --show-progress --progress=dot:giga -O "$FRONTEND_TAR" -L "https://github.com/versatiles-org/versatiles-frontend/releases/latest/download/frontend.br.tar"
fi
