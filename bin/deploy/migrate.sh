#!/usr/bin/env bash
set -euo pipefail

# Migration script for combining download.versatiles.org into tiles.versatiles.org
# This script performs the full migration in phases

cd "$(dirname "$0")/../.."

source .env

echo "============================================"
echo "tiles.versatiles.org Migration"
echo "============================================"
echo ""
echo "This script will:"
echo "  - Create volume directories"
echo "  - Create dummy SSL certificates"
echo "  - Initialize RAM disk"
echo "  - Download frontend and tile data"
echo "  - Start Docker services"
echo "  - Generate download nginx config (with WebDAV proxy)"
echo ""
echo "Prerequisites:"
echo "  - .env file configured (including STORAGE_PASS)"
echo "  - SSH key at .ssh/storage"
echo "  - Run ./bin/deploy/preflight.sh first"
echo ""
read -p "Continue with migration? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

PHASE=0

next_phase() {
    PHASE=$((PHASE + 1))
    echo ""
    echo "============================================"
    echo "Phase $PHASE: $1"
    echo "============================================"
}

# Phase 1: System preparation
next_phase "System Preparation"

echo "Configuring system settings..."
if [ "$(id -u)" -eq 0 ]; then
    echo "vm.max_map_count=262144" > /etc/sysctl.d/99-versatiles.conf
    sysctl -p /etc/sysctl.d/99-versatiles.conf
else
    sudo bash -c 'echo "vm.max_map_count=262144" > /etc/sysctl.d/99-versatiles.conf'
    sudo sysctl -p /etc/sysctl.d/99-versatiles.conf
fi
echo "✓ System settings configured"

# Phase 2: Create directories
next_phase "Creating Volume Directories"

mkdir -p volumes/download/nginx_conf
mkdir -p volumes/download/hash_cache
mkdir -p volumes/versatiles
mkdir -p volumes/cache
mkdir -p volumes/certbot-cert
mkdir -p volumes/certbot-www
mkdir -p volumes/nginx-cert
mkdir -p volumes/nginx-log

echo "✓ All volume directories created"

# Phase 3: Dummy certificates
next_phase "Creating Dummy SSL Certificates"

./bin/cert/create_dummy.sh "${DOMAIN_NAME}"
./bin/cert/create_dummy.sh "${DOWNLOAD_DOMAIN}"

echo "✓ Dummy certificates created for both domains"

# Phase 4: RAM disk
next_phase "Initializing RAM Disk"

if mountpoint -q "./volumes/cache"; then
    echo "✓ RAM disk already mounted"
else
    ./bin/ramdisk/init.sh
fi

# Phase 5: Download frontend
next_phase "Downloading Frontend"

echo "Downloading frontend..."
./bin/frontend/update.sh

echo "✓ Frontend downloaded"

# Phase 6: Start download-updater and fetch tile data
next_phase "Downloading Tile Data"

echo "Starting download-updater container..."
docker compose up --detach --build download-updater

echo "Running download pipeline (this may take a while)..."
docker compose exec download-updater npx tsx src/run_once.ts

echo "✓ Tile data downloaded"

# Phase 7: Start Docker
next_phase "Starting Docker Services"

docker compose up --detach --build

echo "Waiting for services to start..."
sleep 10

# Check service health
for service in versatiles download-updater nginx; do
    if docker compose ps --format json "$service" 2>/dev/null | grep -q "running"; then
        echo "✓ $service is running"
    else
        echo "✗ $service failed to start"
        docker compose logs "$service" --tail=20
        exit 1
    fi
done

# Reload nginx to pick up configuration
echo "Reloading nginx..."
docker compose exec nginx nginx -s reload

echo "✓ All services running"

# Phase 8: Instructions for SSL
next_phase "Final Steps (Manual)"

echo ""
echo "Migration Phase 1 Complete!"
echo ""
echo "============================================"
echo "IMPORTANT: Manual Steps Required"
echo "============================================"
echo ""
echo "1. Update DNS records:"
echo "   - Point ${DOWNLOAD_DOMAIN} A record to this server's IP"
echo "   - Wait for DNS propagation (check with: dig ${DOWNLOAD_DOMAIN})"
echo ""
echo "2. Once DNS is pointing to this server, obtain Let's Encrypt certificates:"
echo "   ./bin/cert/create_valid.sh ${DOMAIN_NAME}"
echo "   ./bin/cert/create_valid.sh ${DOWNLOAD_DOMAIN}"
echo ""
echo "3. Verify deployment:"
echo "   ./bin/verify.sh"
echo ""
echo "4. Test endpoints:"
echo "   curl -I https://${DOMAIN_NAME}/"
echo "   curl -I https://${DOWNLOAD_DOMAIN}/"
echo "   curl https://${DOWNLOAD_DOMAIN}/osm.versatiles.md5"
echo ""
echo "============================================"
