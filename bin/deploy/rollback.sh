#!/usr/bin/env bash
set -euo pipefail

# Rollback script for tiles.versatiles.org migration
# Use this if migration fails and you need to restore to tiles-only operation

cd "$(dirname "$0")/../.."

echo "============================================"
echo "Rollback Migration"
echo "============================================"
echo ""
echo "This will:"
echo "  - Stop all Docker services"
echo "  - Restart only tiles-related services (without download-updater)"
echo ""
echo "IMPORTANT: You must manually update DNS to point"
echo "download.versatiles.org back to the old server!"
echo ""
read -p "Continue with rollback? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "Stopping all Docker services..."
docker compose down

echo ""
echo "Restarting tiles-only services..."
# Start only versatiles and nginx without download-updater
docker compose up --detach versatiles nginx

echo ""
echo "============================================"
echo "Rollback Complete"
echo "============================================"
echo ""
echo "MANUAL STEPS REQUIRED:"
echo "  1. Update DNS: Point download.versatiles.org back to old server"
echo "  2. Restart services on old download server"
echo ""
echo "Current service status:"
docker compose ps
