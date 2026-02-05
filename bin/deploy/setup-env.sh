#!/usr/bin/env bash
set -euo pipefail

# Interactive setup script for .env configuration

cd "$(dirname "$0")/../.."

echo "============================================"
echo "Environment Configuration Setup"
echo "============================================"
echo ""

if [ -f ".env" ]; then
    echo "Warning: .env file already exists."
    read -p "Overwrite existing .env? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Keeping existing .env file."
        exit 0
    fi
fi

# Copy template
cp template.env .env

echo ""
echo "Setting up .env configuration..."
echo ""

# Domain names (defaults from template)
read -p "Tiles domain [tiles.versatiles.org]: " DOMAIN_NAME
DOMAIN_NAME=${DOMAIN_NAME:-tiles.versatiles.org}
sed -i "s/^DOMAIN_NAME=.*/DOMAIN_NAME=${DOMAIN_NAME}/" .env

read -p "Download domain [download.versatiles.org]: " DOWNLOAD_DOMAIN
DOWNLOAD_DOMAIN=${DOWNLOAD_DOMAIN:-download.versatiles.org}
sed -i "s/^DOWNLOAD_DOMAIN=.*/DOWNLOAD_DOMAIN=${DOWNLOAD_DOMAIN}/" .env

# RAM disk
read -p "RAM disk size in GB [4]: " RAM_DISK_GB
RAM_DISK_GB=${RAM_DISK_GB:-4}
sed -i "s/^RAM_DISK_GB=.*/RAM_DISK_GB=${RAM_DISK_GB}/" .env

# Email
read -p "Email for Let's Encrypt [mail@versatiles.org]: " EMAIL
EMAIL=${EMAIL:-mail@versatiles.org}
sed -i "s/^EMAIL=.*/EMAIL=${EMAIL}/" .env

# BBOX
echo ""
echo "Bounding box for tile data (leave empty for full planet)"
echo "Format: west,south,east,north (e.g., -9,36,-6,42 for Portugal)"
read -p "BBOX []: " BBOX
sed -i "s/^BBOX=.*/BBOX=${BBOX}/" .env

# Storage URL
echo ""
echo "Storage box SSH URL (e.g., user@host.your-storagebox.de)"
read -p "STORAGE_URL: " STORAGE_URL
sed -i "s/^STORAGE_URL=.*/STORAGE_URL=${STORAGE_URL}/" .env

# Storage Password (for WebDAV)
echo ""
echo "Storage box password (for WebDAV proxy)"
read -sp "STORAGE_PASS: " STORAGE_PASS
echo ""
sed -i "s/^STORAGE_PASS=.*/STORAGE_PASS=${STORAGE_PASS}/" .env

# Generate webhook secret
echo ""
echo "Generating secure webhook secret..."
WEBHOOK=$(openssl rand -hex 32)
sed -i "s/^WEBHOOK=.*/WEBHOOK=${WEBHOOK}/" .env

echo ""
echo "============================================"
echo "Configuration saved to .env"
echo "============================================"
echo ""
# Show config without sensitive values
grep -v "PASS\|WEBHOOK" .env
echo "STORAGE_PASS=********"
echo "WEBHOOK=********"
echo ""
echo "============================================"
echo "Next steps:"
echo "============================================"
echo "1. Setup SSH key:"
echo "   mkdir -p .ssh"
echo "   cp /path/to/your/storage-key .ssh/storage"
echo "   chmod 600 .ssh/storage"
echo ""
echo "2. Run preflight check:"
echo "   ./bin/deploy/preflight.sh"
echo ""
echo "3. Start migration:"
echo "   ./bin/deploy/migrate.sh"
echo ""
