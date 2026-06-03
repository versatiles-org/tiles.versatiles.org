#!/usr/bin/env bash
set -euo pipefail

# Post-deployment verification script for tiles.versatiles.org
# Run this AFTER deployment to verify everything is working

cd "$(dirname "$0")/.."

source .env

echo "============================================"
echo "Post-Deployment Verification"
echo "============================================"
echo ""

ERRORS=0
WARNINGS=0

pass() { echo -e "   \033[0;32m✓ $*\033[0m"; }
fail() { echo -e "   \033[0;31m✗ $*\033[0m"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "   \033[0;33m⚠ $*\033[0m"; WARNINGS=$((WARNINGS + 1)); }

# Check Docker services
echo "1. Checking Docker services..."
SERVICES="versatiles nginx"
for service in $SERVICES; do
    # Check if container is running using docker compose ps with grep
    if docker compose ps --status running 2>/dev/null | grep -q "$service"; then
        pass "$service is running"
    elif docker compose ps 2>/dev/null | grep -E "$service.*Up" > /dev/null; then
        pass "$service is running"
    else
        fail "$service is NOT running"
    fi
done

# Check nginx config
echo ""
echo "2. Checking nginx configuration..."
if docker compose exec -T nginx nginx -t &> /dev/null; then
    pass "Nginx configuration is valid"
else
    fail "Nginx configuration is invalid"
    docker compose exec -T nginx nginx -t 2>&1 | head -5
fi

# Check SSL certificates
echo ""
echo "3. Checking SSL certificates..."
CERT_PATH="./volumes/nginx-cert/live/${DOMAIN_NAME}/fullchain.pem"
if [ -f "$CERT_PATH" ]; then
    # Check if it's a real cert or dummy
    ISSUER=$(openssl x509 -in "$CERT_PATH" -noout -issuer 2>/dev/null || echo "")
    if echo "$ISSUER" | grep -qi "Let's Encrypt\|R3\|E1\|R10\|R11"; then
        EXPIRY=$(openssl x509 -in "$CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)
        pass "${DOMAIN_NAME} has valid Let's Encrypt certificate (expires: $EXPIRY)"
    else
        warn "${DOMAIN_NAME} has dummy/self-signed certificate"
        echo "     → Run: ./bin/cert/create_valid.sh ${DOMAIN_NAME}"
    fi
else
    fail "${DOMAIN_NAME} certificate not found"
fi

# Test HTTP endpoints
echo ""
echo "4. Testing HTTP endpoints..."

# Tiles domain
echo "   Testing ${DOMAIN_NAME}..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${DOMAIN_NAME}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "301" ]; then
    pass "HTTP redirect working (301)"
else
    warn "HTTP returned $HTTP_CODE (expected 301)"
fi

HTTPS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOMAIN_NAME}/" 2>/dev/null || echo "000")
if [ "$HTTPS_CODE" = "200" ]; then
    pass "HTTPS working (200)"
else
    warn "HTTPS returned $HTTPS_CODE (expected 200)"
fi

# Test tile endpoints
echo ""
echo "5. Testing tile endpoints..."
for tileset in osm satellite elevation; do
    TILE_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOMAIN_NAME}/tiles/${tileset}/0/0/0" 2>/dev/null || echo "000")
    if [ "$TILE_CODE" = "200" ]; then
        pass "Tile endpoint working: ${tileset}"
    else
        warn "Tile endpoint ${tileset} returned $TILE_CODE"
    fi
done

# Test style JSON
echo ""
echo "6. Testing style JSON..."
STYLE_URL="https://${DOMAIN_NAME}/assets/styles/colorful/style.json"
if curl -sk "$STYLE_URL" 2>/dev/null | python3 -m json.tool >/dev/null 2>&1; then
    pass "Style JSON is valid"
else
    fail "Style JSON is invalid or missing"
fi

# Test CORS headers on various endpoints
echo ""
echo "7. Checking CORS headers..."
CORS_PATHS=(
    "/tiles/osm/0/0/0"
    "/assets/sprites/basics/sprites.json"
    "/assets/fonts/fonts.json"
    "/assets/styles/neutrino.json"
)
for path in "${CORS_PATHS[@]}"; do
    CORS_HEADER=$(curl -sk -o /dev/null -w "%{http_code}" -H "Origin: https://example.com" -D - "https://${DOMAIN_NAME}${path}" 2>/dev/null | grep -i "access-control-allow-origin" || echo "")
    if [ -n "$CORS_HEADER" ]; then
        pass "CORS header present on ${path}"
    else
        fail "CORS header missing on ${path}"
    fi
done

# Check cron job
echo ""
echo "8. Checking certificate renewal cron job..."
if crontab -l 2>/dev/null | grep -q "bin/cert/renew.sh"; then
    pass "Certificate renewal cron job is configured"
else
    warn "Certificate renewal cron job not found"
    echo "     → Run: ./bin/cert/setup_renewal.sh"
fi

# Check log rotation cron job
echo ""
echo "9. Checking log rotation cron job..."
if crontab -l 2>/dev/null | grep -q "bin/log/rotate.sh"; then
    pass "Log rotation cron job is configured"
else
    warn "Log rotation cron job not found"
    echo "     → Run: ./bin/log/setup_rotation.sh"
fi

# Check volume directories
echo ""
echo "10. Checking volume directories..."
VOLUME_DIRS="volumes/tiles volumes/frontend volumes/cache volumes/download/hash_cache volumes/certbot-cert volumes/certbot-www volumes/nginx-cert volumes/nginx-log volumes/versatiles_conf"
for dir in $VOLUME_DIRS; do
    if [ -d "$dir" ]; then
        pass "$dir exists"
    else
        fail "$dir is missing"
    fi
done

# Check updater-written volumes are writable by UID 1001
for dir in volumes/tiles volumes/download/hash_cache volumes/versatiles_conf; do
    OWNER=$(stat -c '%u' "$dir" 2>/dev/null || stat -f '%u' "$dir" 2>/dev/null || echo "unknown")
    if [ "$OWNER" = "1001" ]; then
        pass "$dir owned by appuser (1001)"
    else
        warn "$dir owned by UID $OWNER (expected 1001)"
        echo "     → Run: chown 1001:1001 $dir"
    fi
done

# Check RAM disk
if mountpoint -q volumes/cache 2>/dev/null; then
    pass "volumes/cache is a mounted filesystem (RAM disk)"
else
    warn "volumes/cache is not a separate mount (RAM disk not configured?)"
    echo "     → Run: ./bin/ramdisk/init.sh"
fi

# Check nginx rate limit configuration
echo ""
echo "11. Checking nginx rate limit configuration..."
RATE_VALUE=$(docker compose exec -T nginx sh -c "grep -o 'rate=[0-9]*r/s' /etc/nginx/nginx.conf" 2>/dev/null | grep -o '[0-9]*' || echo "")
if [ -n "$RATE_VALUE" ]; then
    if [ "$RATE_VALUE" -ge 50 ]; then
        pass "Rate limit: ${RATE_VALUE}r/s"
    else
        fail "Rate limit too low: ${RATE_VALUE}r/s (expected ≥50)"
    fi
else
    warn "Could not read rate limit from nginx config"
fi

BURST_VALUE=$(docker compose exec -T nginx sh -c "grep -o 'burst=[0-9]*' /etc/nginx/conf.d/proxy.conf" 2>/dev/null | grep -o '[0-9]*' || echo "")
if [ -n "$BURST_VALUE" ]; then
    if [ "$BURST_VALUE" -ge 200 ]; then
        pass "Burst limit: ${BURST_VALUE}"
    else
        fail "Burst limit too low: ${BURST_VALUE} (expected ≥200)"
    fi
else
    warn "Could not read burst limit from nginx config"
fi

# Summary
echo ""
echo "============================================"
echo "Verification Summary"
echo "============================================"
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "\033[0;32m✓ All checks passed! Deployment successful.\033[0m"
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo -e "\033[0;33m⚠ $WARNINGS warning(s). Deployment mostly successful but review warnings.\033[0m"
    exit 0
else
    echo -e "\033[0;31m✗ $ERRORS error(s), $WARNINGS warning(s). Please resolve issues.\033[0m"
    exit 1
fi
