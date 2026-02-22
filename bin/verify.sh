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
SERVICES="versatiles download-updater nginx"
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
if docker exec nginx nginx -t &> /dev/null; then
    pass "Nginx configuration is valid"
else
    fail "Nginx configuration is invalid"
    docker exec nginx nginx -t 2>&1 | head -5
fi

# Check generated download config
echo ""
echo "3. Checking download nginx config..."
if [ -f "./volumes/download/nginx_conf/download.conf" ]; then
    pass "download.conf exists"

    if grep -q "server_name ${DOWNLOAD_DOMAIN}" ./volumes/download/nginx_conf/download.conf; then
        pass "download.conf contains correct domain"
    else
        fail "download.conf has wrong domain"
    fi

    # Check for WebDAV proxy configuration
    if grep -q "proxy_pass https://" ./volumes/download/nginx_conf/download.conf; then
        pass "download.conf contains WebDAV proxy configuration"
    else
        warn "download.conf missing WebDAV proxy (may be OK if all files are local)"
    fi
else
    fail "download.conf not found - run: ./bin/download-updater/update.sh"
fi

# Check SSL certificates
echo ""
echo "4. Checking SSL certificates..."
for domain in "${DOMAIN_NAME}" "${DOWNLOAD_DOMAIN}"; do
    CERT_PATH="./volumes/nginx-cert/live/${domain}/fullchain.pem"
    if [ -f "$CERT_PATH" ]; then
        # Check if it's a real cert or dummy
        ISSUER=$(openssl x509 -in "$CERT_PATH" -noout -issuer 2>/dev/null || echo "")
        if echo "$ISSUER" | grep -qi "Let's Encrypt\|R3\|E1\|R10\|R11"; then
            EXPIRY=$(openssl x509 -in "$CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)
            pass "$domain has valid Let's Encrypt certificate (expires: $EXPIRY)"
        else
            warn "$domain has dummy/self-signed certificate"
            echo "     → Run: ./bin/cert/create_valid.sh $domain"
        fi
    else
        fail "$domain certificate not found"
    fi
done

# Test HTTP endpoints
echo ""
echo "5. Testing HTTP endpoints..."

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

# Download domain
echo "   Testing ${DOWNLOAD_DOMAIN}..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${DOWNLOAD_DOMAIN}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "301" ]; then
    pass "HTTP redirect working (301)"
else
    warn "HTTP returned $HTTP_CODE (expected 301)"
fi

HTTPS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOWNLOAD_DOMAIN}/" 2>/dev/null || echo "000")
if [ "$HTTPS_CODE" = "200" ]; then
    pass "HTTPS working (200)"
else
    warn "HTTPS returned $HTTPS_CODE (expected 200)"
fi

# Test tile endpoint
echo ""
echo "6. Testing tile endpoint..."
TILE_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOMAIN_NAME}/tiles/osm/0/0/0" 2>/dev/null || echo "000")
if [ "$TILE_CODE" = "200" ]; then
    pass "Tile endpoint working"
else
    warn "Tile endpoint returned $TILE_CODE"
fi

# Test style JSON
echo ""
echo "7. Testing style JSON..."
STYLE_URL="https://${DOMAIN_NAME}/assets/styles/colorful/style.json"
if curl -sk "$STYLE_URL" 2>/dev/null | python3 -m json.tool >/dev/null 2>&1; then
    pass "Style JSON is valid"
else
    fail "Style JSON is invalid or missing"
fi

# Test CORS headers on various endpoints
echo ""
echo "8. Checking CORS headers..."
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

# Test download file (local file)
echo ""
echo "9. Testing download endpoints..."
echo "   Testing local file (osm.versatiles)..."
LOCAL_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -I "https://${DOWNLOAD_DOMAIN}/osm.versatiles" 2>/dev/null || echo "000")
if [ "$LOCAL_CODE" = "200" ]; then
    pass "Local file endpoint working"
else
    warn "Local file returned $LOCAL_CODE"
fi

echo "   Testing checksum file..."
CHECKSUM_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOWNLOAD_DOMAIN}/osm.versatiles.md5" 2>/dev/null || echo "000")
if [ "$CHECKSUM_CODE" = "200" ]; then
    pass "Checksum endpoint working"
else
    warn "Checksum endpoint returned $CHECKSUM_CODE"
fi

# Test WebDAV proxy (remote versioned file)
echo ""
echo "10. Testing WebDAV proxy for remote files..."
# Find a remote file from the nginx config
REMOTE_FILE=$(grep -o 'location = /[^{]*\.versatiles' ./volumes/download/nginx_conf/download.conf 2>/dev/null | grep -v '/osm\.versatiles' | head -1 | sed 's/location = //' || echo "")
if [ -n "$REMOTE_FILE" ]; then
    REMOTE_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -I "https://${DOWNLOAD_DOMAIN}${REMOTE_FILE}" 2>/dev/null || echo "000")
    if [ "$REMOTE_CODE" = "200" ]; then
        pass "WebDAV proxy working (${REMOTE_FILE})"
    else
        fail "WebDAV proxy returned $REMOTE_CODE for ${REMOTE_FILE}"
    fi
else
    warn "No remote files found to test"
fi

# Test RSS feed
echo ""
echo "11. Testing RSS feeds..."
RSS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOWNLOAD_DOMAIN}/feed-osm.xml" 2>/dev/null || echo "000")
if [ "$RSS_CODE" = "200" ]; then
    pass "RSS feed working"
else
    warn "RSS feed returned $RSS_CODE"
fi

# Test webhook
echo ""
echo "12. Testing webhook endpoint..."
if [ -n "${WEBHOOK:-}" ]; then
    WEBHOOK_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOWNLOAD_DOMAIN}/${WEBHOOK}" 2>/dev/null || echo "000")
    if [ "$WEBHOOK_CODE" = "200" ] || [ "$WEBHOOK_CODE" = "202" ]; then
        pass "Webhook endpoint accessible"
    else
        warn "Webhook returned $WEBHOOK_CODE"
    fi
else
    warn "WEBHOOK not set in .env"
fi

# Check cron job
echo ""
echo "13. Checking certificate renewal cron job..."
if crontab -l 2>/dev/null | grep -q "bin/cert/renew.sh"; then
    pass "Certificate renewal cron job is configured"
else
    warn "Certificate renewal cron job not found"
    echo "     → Run: ./bin/cert/setup_renewal.sh"
fi

# Check nginx rate limit configuration
echo ""
echo "14. Checking nginx rate limit configuration..."
RATE_VALUE=$(docker exec nginx sh -c "grep -o 'rate=[0-9]*r/s' /etc/nginx/nginx.conf" 2>/dev/null | grep -o '[0-9]*' || echo "")
if [ -n "$RATE_VALUE" ]; then
    if [ "$RATE_VALUE" -ge 50 ]; then
        pass "Rate limit: ${RATE_VALUE}r/s"
    else
        fail "Rate limit too low: ${RATE_VALUE}r/s (expected ≥50)"
    fi
else
    warn "Could not read rate limit from nginx config"
fi

BURST_VALUE=$(docker exec nginx sh -c "grep -o 'burst=[0-9]*' /etc/nginx/conf.d/proxy.conf" 2>/dev/null | grep -o '[0-9]*' || echo "")
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
