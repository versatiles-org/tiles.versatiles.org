#!/usr/bin/env bash
set -euo pipefail

# Fresh server setup script for tiles.versatiles.org
# Run this after: installing Docker, cloning the repo, configuring .env, and copying the SSH key.

cd "$(dirname "$0")/../.."

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
if [ -f .env ]; then
	pass ".env file exists"
	source .env

	REQUIRED_VARS="DOMAIN_NAME DOWNLOAD_DOMAIN RAM_DISK_GB EMAIL STORAGE_URL STORAGE_PASS"
	for var in $REQUIRED_VARS; do
		if [ -n "${!var:-}" ]; then
			pass "$var is set"
		else
			fail "$var is not set in .env"
		fi
	done
else
	fail ".env file not found (copy template.env to .env and fill in values)"
fi

# Check SSH key
if [ -f .ssh/storage ]; then
	pass ".ssh/storage key exists"
else
	fail ".ssh/storage key not found"
fi

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

# --- Helpers ---

wait_for_healthy() {
	local service="$1"
	local timeout="${2:-120}"
	local elapsed=0
	echo "Waiting for $service to be healthy..."
	while [ $elapsed -lt "$timeout" ]; do
		if docker compose ps --format json "$service" 2>/dev/null | grep -q '"healthy"'; then
			echo "$service is healthy."
			return 0
		fi
		sleep 2
		elapsed=$((elapsed + 2))
	done
	echo "Error: $service did not become healthy within ${timeout}s"
	exit 1
}

# --- Deployment ---

echo "Starting deployment..."
echo ""

# 1. Ensure infrastructure (volumes, RAM disk, cron jobs)
./bin/deploy/ensure.sh

# 2. Fetch frontend
echo "Fetching frontend..."
./bin/frontend/update.sh

# 3. Fetch styles
echo "Fetching styles..."
./bin/styles/update.sh

# 4. Pull Docker images
echo "Pulling Docker images..."
docker compose pull

# 5. Build custom images
echo "Building Docker images..."
docker compose build
docker compose build download-updater

# 6. Create dummy SSL certificates
echo "Creating dummy SSL certificates..."
./bin/cert/create_dummy.sh "$DOMAIN_NAME"
./bin/cert/create_dummy.sh "$DOWNLOAD_DOMAIN"

# 7. Start services
echo "Starting services..."
docker compose up --detach
wait_for_healthy nginx

# 8. Run download pipeline
echo "Running download pipeline..."
docker compose run --rm download-updater

# 9. Reload nginx
echo "Reloading nginx..."
docker compose exec nginx nginx -s reload

# 10. Create valid Let's Encrypt certificates
echo "Creating Let's Encrypt certificates..."
./bin/cert/create_valid.sh "$DOMAIN_NAME"
./bin/cert/create_valid.sh "$DOWNLOAD_DOMAIN"

# 11. Verify deployment
echo ""
echo "Running verification..."
./bin/verify.sh

echo ""
echo "Setup complete!"
