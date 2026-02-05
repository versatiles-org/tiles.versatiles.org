#!/usr/bin/env bash
set -euo pipefail

# Pre-flight check script for tiles.versatiles.org migration
# Run this BEFORE starting the migration to verify server readiness

cd "$(dirname "$0")/../.."

echo "============================================"
echo "Pre-flight Checks for Migration"
echo "============================================"
echo ""

ERRORS=0

# Check if running as root or with sudo capability
echo "1. Checking user privileges..."
if [ "$(id -u)" -eq 0 ]; then
    echo "   ✓ Running as root"
elif sudo -n true 2>/dev/null; then
    echo "   ✓ Has sudo privileges"
else
    echo "   ✗ Not running as root and no passwordless sudo available"
    echo "     → Run as root or configure sudo"
    ERRORS=$((ERRORS + 1))
fi

# Check for required packages
echo ""
echo "2. Checking required packages..."

check_command() {
    if command -v "$1" &> /dev/null; then
        echo "   ✓ $1 found"
        return 0
    else
        echo "   ✗ $1 not found"
        echo "     → Install with: apt install $2"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
}

check_command docker docker.io
check_command openssl openssl
check_command curl curl
check_command wget wget

# Check Docker Compose
echo ""
echo "3. Checking Docker Compose..."
if docker compose version &> /dev/null; then
    echo "   ✓ Docker Compose (plugin) found"
elif docker-compose --version &> /dev/null; then
    echo "   ⚠ docker-compose (standalone) found - prefer 'docker compose' plugin"
else
    echo "   ✗ Docker Compose not found"
    ERRORS=$((ERRORS + 1))
fi

# Check if Docker daemon is running
echo ""
echo "4. Checking Docker daemon..."
if docker info &> /dev/null; then
    echo "   ✓ Docker daemon is running"
else
    echo "   ✗ Docker daemon is not running"
    echo "     → Start with: systemctl start docker"
    ERRORS=$((ERRORS + 1))
fi

# Check .env file exists
echo ""
echo "5. Checking .env file..."
if [ -f ".env" ]; then
    echo "   ✓ .env file exists"

    # Source and validate required variables
    source .env

    REQUIRED_VARS="DOMAIN_NAME DOWNLOAD_DOMAIN RAM_DISK_GB EMAIL STORAGE_URL STORAGE_PASS WEBHOOK"
    for var in $REQUIRED_VARS; do
        if [ -z "${!var:-}" ]; then
            echo "   ✗ Missing required variable: $var"
            ERRORS=$((ERRORS + 1))
        else
            if [ "$var" = "WEBHOOK" ] || [ "$var" = "STORAGE_URL" ] || [ "$var" = "STORAGE_PASS" ]; then
                echo "   ✓ $var is set (value hidden)"
            else
                echo "   ✓ $var = ${!var}"
            fi
        fi
    done
else
    echo "   ✗ .env file not found"
    echo "     → Copy template.env to .env and configure values"
    ERRORS=$((ERRORS + 1))
fi

# Check SSH key for storage
echo ""
echo "6. Checking SSH key for storage box..."
if [ -f ".ssh/storage" ]; then
    echo "   ✓ SSH key exists at .ssh/storage"

    PERMS=$(stat -c %a .ssh/storage 2>/dev/null || stat -f %A .ssh/storage 2>/dev/null)
    if [ "$PERMS" = "600" ]; then
        echo "   ✓ SSH key has correct permissions (600)"
    else
        echo "   ⚠ SSH key permissions are $PERMS (should be 600)"
        echo "     → Fix with: chmod 600 .ssh/storage"
    fi
else
    echo "   ✗ SSH key not found at .ssh/storage"
    echo "     → Create .ssh directory and copy/generate SSH key"
    ERRORS=$((ERRORS + 1))
fi

# Test SSH connection to storage
echo ""
echo "7. Testing SSH connection to storage box..."
if [ -f ".env" ] && [ -f ".ssh/storage" ]; then
    source .env
    if [ -n "${STORAGE_URL:-}" ]; then
        if timeout 10 ssh -i .ssh/storage -p 23 -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${STORAGE_URL}" ls /home &> /dev/null; then
            echo "   ✓ SSH connection to storage box successful"
        else
            echo "   ✗ SSH connection failed"
            echo "     → Check SSH key and STORAGE_URL in .env"
            echo "     → Test manually: ssh -i .ssh/storage -p 23 \${STORAGE_URL} ls /home"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "   ⚠ STORAGE_URL not set, skipping SSH test"
    fi
else
    echo "   ⚠ Missing .env or SSH key, skipping SSH test"
fi

# Test WebDAV connection
echo ""
echo "8. Testing WebDAV connection to storage box..."
if [ -f ".env" ]; then
    source .env
    if [ -n "${STORAGE_URL:-}" ] && [ -n "${STORAGE_PASS:-}" ]; then
        # Extract user and host from STORAGE_URL (user@host format)
        WEBDAV_USER=$(echo "${STORAGE_URL}" | cut -d@ -f1)
        WEBDAV_HOST=$(echo "${STORAGE_URL}" | cut -d@ -f2)
        if curl -sf -u "${WEBDAV_USER}:${STORAGE_PASS}" "https://${WEBDAV_HOST}/" > /dev/null; then
            echo "   ✓ WebDAV connection successful"
        else
            echo "   ✗ WebDAV connection failed"
            echo "     → Check STORAGE_URL and STORAGE_PASS in .env"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "   ⚠ STORAGE_URL or STORAGE_PASS not set, skipping WebDAV test"
    fi
else
    echo "   ⚠ Missing .env, skipping WebDAV test"
fi

# Check disk space
echo ""
echo "9. Checking disk space..."
AVAILABLE_GB=$(df -BG . | tail -1 | awk '{print $4}' | tr -d 'G')
if [ "$AVAILABLE_GB" -ge 100 ]; then
    echo "   ✓ Available disk space: ${AVAILABLE_GB}GB (recommended: 100GB+)"
else
    echo "   ⚠ Available disk space: ${AVAILABLE_GB}GB (recommended: 100GB+)"
    echo "     → Consider freeing up space or using larger disk"
fi

# Check available RAM
echo ""
echo "10. Checking available RAM..."
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM_GB" -ge 8 ]; then
    echo "   ✓ Total RAM: ${TOTAL_RAM_GB}GB (recommended: 8GB+)"
else
    echo "   ⚠ Total RAM: ${TOTAL_RAM_GB}GB (recommended: 8GB+)"
fi

# Check if ports 80 and 443 are available
echo ""
echo "11. Checking port availability..."
for port in 80 443; do
    if ! ss -tuln | grep -q ":${port} " 2>/dev/null; then
        echo "   ✓ Port $port is available"
    else
        echo "   ⚠ Port $port is in use"
        ss -tuln | grep ":${port} " | head -1
        echo "     → Existing services will be replaced when Docker starts"
    fi
done

# Summary
echo ""
echo "============================================"
echo "Pre-flight Check Summary"
echo "============================================"
if [ $ERRORS -eq 0 ]; then
    echo "✓ All checks passed! Ready for migration."
    exit 0
else
    echo "✗ $ERRORS check(s) failed. Please resolve issues before proceeding."
    exit 1
fi
