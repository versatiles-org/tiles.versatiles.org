#!/usr/bin/env bash
set -euo pipefail

# Fresh server setup script for tiles.versatiles.org
# Run this after: installing Docker, cloning the repo, configuring .env, and copying the SSH key.

cd "$(dirname "$0")/../.."
source bin/deploy/helpers.sh
source .env

echo "============================================"
echo "tiles.versatiles.org — Fresh Server Setup"
echo "============================================"
echo ""

# --- Preflight Checks ---

echo "Running preflight checks..."

ERRORS=0
fail() { echo -e "  \033[0;31m✗ $*\033[0m"; ERRORS=$((ERRORS + 1)); }
pass() { echo -e "  \033[0;32m✓ $*\033[0m"; }

# Check Docker
if command -v docker &>/dev/null; then
	pass "Docker is installed"
else
	fail "Docker is not installed"
fi

# Check Docker Compose
if docker compose version &>/dev/null; then
	pass "Docker Compose is installed"
else
	fail "Docker Compose is not installed"
fi

# Check .env file and required variables
REQUIRED_VARS="DOMAIN_NAME RAM_DISK_GB EMAIL"
for var in $REQUIRED_VARS; do
	if [ -n "${!var:-}" ]; then
		pass "$var is set"
	else
		fail "$var is not set in .env"
	fi
done

# Check ports 80 and 443
for port in 80 443; do
	if ss -tlnp 2>/dev/null | grep -q ":${port} " || lsof -i ":${port}" &>/dev/null; then
		fail "Port ${port} is already in use"
	else
		pass "Port ${port} is available"
	fi
done

if [ "$ERRORS" -gt 0 ]; then
	echo ""
	echo -e "\033[0;31mPreflight failed with $ERRORS error(s). Fix the issues above and re-run.\033[0m"
	exit 1
fi

echo ""
echo "All preflight checks passed."
echo ""

# --- Deployment ---

echo "Starting deployment..."
echo ""

# 1. Build (ensure, fetch assets, pull/build images)
# build.sh exits 10 when it downloaded a new frontend/styles bundle. On a fresh
# server that always happens, and there is nothing running yet to restart or
# cache to clear, so treat 10 the same as success here. Any other non-zero exit
# is a real failure.
set +e
./bin/deploy/build.sh
BUILD_EXIT=$?
set -e
if [ $BUILD_EXIT -ne 0 ] && [ $BUILD_EXIT -ne 10 ]; then
	echo "ERROR: build.sh failed (exit $BUILD_EXIT)."
	exit 1
fi

# 2. Run download pipeline (initial population — fresh server has no local files)
echo "Running download pipeline..."
docker compose run --rm download-updater

# 3. Create dummy SSL certificates
echo "Creating dummy SSL certificates..."
./bin/cert/create_dummy.sh "$DOMAIN_NAME"

# 4. Start services
echo "Starting services..."
docker compose up --detach
wait_for_healthy nginx

# 5. Create valid Let's Encrypt certificates
echo "Creating Let's Encrypt certificates..."
./bin/cert/create_valid.sh "$DOMAIN_NAME"

# 7. Verify deployment
echo ""
echo "Running verification..."
./bin/verify.sh

echo ""
echo "Setup complete!"
