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

# Check Docker services
echo "1. Checking Docker services..."
SERVICES="versatiles download-updater nginx"
for service in $SERVICES; do
    # Check if container is running using docker compose ps with grep
    if docker compose ps --status running 2>/dev/null | grep -q "$service"; then
        echo "   ✓ $service is running"
    elif docker compose ps 2>/dev/null | grep -E "$service.*Up" > /dev/null; then
        echo "   ✓ $service is running"
    else
        echo "   ✗ $service is NOT running"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check nginx config
echo ""
echo "2. Checking nginx configuration..."
if docker exec nginx nginx -t &> /dev/null; then
    echo "   ✓ Nginx configuration is valid"
else
    echo "   ✗ Nginx configuration is invalid"
    docker exec nginx nginx -t 2>&1 | head -5
    ERRORS=$((ERRORS + 1))
fi

# Check generated download config
echo ""
echo "3. Checking download nginx config..."
if [ -f "./volumes/download/nginx_conf/download.conf" ]; then
    echo "   ✓ download.conf exists"

    if grep -q "server_name ${DOWNLOAD_DOMAIN}" ./volumes/download/nginx_conf/download.conf; then
        echo "   ✓ download.conf contains correct domain"
    else
        echo "   ✗ download.conf has wrong domain"
        ERRORS=$((ERRORS + 1))
    fi

    # Check for WebDAV proxy configuration
    if grep -q "proxy_pass https://" ./volumes/download/nginx_conf/download.conf; then
        echo "   ✓ download.conf contains WebDAV proxy configuration"
    else
        echo "   ⚠ download.conf missing WebDAV proxy (may be OK if all files are local)"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo "   ✗ download.conf not found - run: ./bin/download-updater/update.sh"
    ERRORS=$((ERRORS + 1))
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
            echo "   ✓ $domain has valid Let's Encrypt certificate (expires: $EXPIRY)"
        else
            echo "   ⚠ $domain has dummy/self-signed certificate"
            echo "     → Run: ./bin/cert/create_valid.sh $domain"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        echo "   ✗ $domain certificate not found"
        ERRORS=$((ERRORS + 1))
    fi
done

# Test HTTP endpoints
echo ""
echo "5. Testing HTTP endpoints..."

# Tiles domain
echo "   Testing ${DOMAIN_NAME}..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${DOMAIN_NAME}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "301" ]; then
    echo "   ✓ HTTP redirect working (301)"
else
    echo "   ⚠ HTTP returned $HTTP_CODE (expected 301)"
    WARNINGS=$((WARNINGS + 1))
fi

HTTPS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOMAIN_NAME}/" 2>/dev/null || echo "000")
if [ "$HTTPS_CODE" = "200" ]; then
    echo "   ✓ HTTPS working (200)"
else
    echo "   ⚠ HTTPS returned $HTTPS_CODE (expected 200)"
    WARNINGS=$((WARNINGS + 1))
fi

# Download domain
echo "   Testing ${DOWNLOAD_DOMAIN}..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${DOWNLOAD_DOMAIN}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "301" ]; then
    echo "   ✓ HTTP redirect working (301)"
else
    echo "   ⚠ HTTP returned $HTTP_CODE (expected 301)"
    WARNINGS=$((WARNINGS + 1))
fi

HTTPS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOWNLOAD_DOMAIN}/" 2>/dev/null || echo "000")
if [ "$HTTPS_CODE" = "200" ]; then
    echo "   ✓ HTTPS working (200)"
else
    echo "   ⚠ HTTPS returned $HTTPS_CODE (expected 200)"
    WARNINGS=$((WARNINGS + 1))
fi

# Test tile endpoint
echo ""
echo "6. Testing tile endpoint..."
TILE_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOMAIN_NAME}/tiles/osm/0/0/0" 2>/dev/null || echo "000")
if [ "$TILE_CODE" = "200" ]; then
    echo "   ✓ Tile endpoint working"
else
    echo "   ⚠ Tile endpoint returned $TILE_CODE"
    WARNINGS=$((WARNINGS + 1))
fi

# Test style JSON
echo ""
echo "7. Testing style JSON..."
STYLE_URL="https://${DOMAIN_NAME}/assets/styles/colorful/style.json"
STYLE_HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$STYLE_URL" 2>/dev/null || echo "000")
STYLE_BODY=$(curl -sk "$STYLE_URL" 2>/dev/null || echo "")
STYLE_CONTENT_TYPE=$(curl -sk -o /dev/null -w "%{content_type}" "$STYLE_URL" 2>/dev/null || echo "")
echo "   HTTP status: $STYLE_HTTP_CODE"
echo "   Content-Type: $STYLE_CONTENT_TYPE"
echo "   Body length: ${#STYLE_BODY}"
echo "   Body (first 200 chars): ${STYLE_BODY:0:200}"
if [ "$STYLE_HTTP_CODE" != "200" ]; then
    echo "   ✗ Style endpoint returned $STYLE_HTTP_CODE"
    ERRORS=$((ERRORS + 1))
elif echo "$STYLE_BODY" | jq empty 2>/dev/null; then
    echo "   ✓ Style JSON is valid"
else
    echo "   ✗ Style JSON is invalid"
    ERRORS=$((ERRORS + 1))
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
        echo "   ✓ CORS header present on ${path}"
    else
        echo "   ✗ CORS header missing on ${path}"
        ERRORS=$((ERRORS + 1))
    fi
done

# Test download file (local file)
echo ""
echo "9. Testing download endpoints..."
echo "   Testing local file (osm.versatiles)..."
LOCAL_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -I "https://${DOWNLOAD_DOMAIN}/osm.versatiles" 2>/dev/null || echo "000")
if [ "$LOCAL_CODE" = "200" ]; then
    echo "   ✓ Local file endpoint working"
else
    echo "   ⚠ Local file returned $LOCAL_CODE"
    WARNINGS=$((WARNINGS + 1))
fi

echo "   Testing checksum file..."
CHECKSUM_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOWNLOAD_DOMAIN}/osm.versatiles.md5" 2>/dev/null || echo "000")
if [ "$CHECKSUM_CODE" = "200" ]; then
    echo "   ✓ Checksum endpoint working"
else
    echo "   ⚠ Checksum endpoint returned $CHECKSUM_CODE"
    WARNINGS=$((WARNINGS + 1))
fi

# Test WebDAV proxy (remote versioned file)
echo ""
echo "10. Testing WebDAV proxy for remote files..."
# Find a remote file from the nginx config
REMOTE_FILE=$(grep -o 'location = /[^{]*\.versatiles' ./volumes/download/nginx_conf/download.conf 2>/dev/null | grep -v '/osm\.versatiles' | head -1 | sed 's/location = //' || echo "")
if [ -n "$REMOTE_FILE" ]; then
    REMOTE_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -I "https://${DOWNLOAD_DOMAIN}${REMOTE_FILE}" 2>/dev/null || echo "000")
    if [ "$REMOTE_CODE" = "200" ]; then
        echo "   ✓ WebDAV proxy working (${REMOTE_FILE})"
    else
        echo "   ✗ WebDAV proxy returned $REMOTE_CODE for ${REMOTE_FILE}"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "   ⚠ No remote files found to test"
    WARNINGS=$((WARNINGS + 1))
fi

# Test RSS feed
echo ""
echo "11. Testing RSS feeds..."
RSS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOWNLOAD_DOMAIN}/feed-osm.xml" 2>/dev/null || echo "000")
if [ "$RSS_CODE" = "200" ]; then
    echo "   ✓ RSS feed working"
else
    echo "   ⚠ RSS feed returned $RSS_CODE"
    WARNINGS=$((WARNINGS + 1))
fi

# Test webhook
echo ""
echo "12. Testing webhook endpoint..."
if [ -n "${WEBHOOK:-}" ]; then
    WEBHOOK_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOWNLOAD_DOMAIN}/${WEBHOOK}" 2>/dev/null || echo "000")
    if [ "$WEBHOOK_CODE" = "200" ] || [ "$WEBHOOK_CODE" = "202" ]; then
        echo "   ✓ Webhook endpoint accessible"
    else
        echo "   ⚠ Webhook returned $WEBHOOK_CODE"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo "   ⚠ WEBHOOK not set in .env"
fi

# Check cron job
echo ""
echo "13. Checking certificate renewal cron job..."
if crontab -l 2>/dev/null | grep -q "bin/cert/renew.sh"; then
    echo "   ✓ Certificate renewal cron job is configured"
else
    echo "   ⚠ Certificate renewal cron job not found"
    echo "     → Run: ./bin/cert/setup_renewal.sh"
    WARNINGS=$((WARNINGS + 1))
fi

# Check nginx rate limit configuration
echo ""
echo "14. Checking nginx rate limit configuration..."
RATE_VALUE=$(docker exec nginx sh -c "grep -o 'rate=[0-9]*r/s' /etc/nginx/nginx.conf" 2>/dev/null | grep -o '[0-9]*' || echo "")
if [ -n "$RATE_VALUE" ]; then
    if [ "$RATE_VALUE" -ge 50 ]; then
        echo "   ✓ Rate limit: ${RATE_VALUE}r/s"
    else
        echo "   ✗ Rate limit too low: ${RATE_VALUE}r/s (expected ≥50)"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "   ⚠ Could not read rate limit from nginx config"
    WARNINGS=$((WARNINGS + 1))
fi

BURST_VALUE=$(docker exec nginx sh -c "grep -o 'burst=[0-9]*' /etc/nginx/conf.d/proxy.conf" 2>/dev/null | grep -o '[0-9]*' || echo "")
if [ -n "$BURST_VALUE" ]; then
    if [ "$BURST_VALUE" -ge 200 ]; then
        echo "   ✓ Burst limit: ${BURST_VALUE}"
    else
        echo "   ✗ Burst limit too low: ${BURST_VALUE} (expected ≥200)"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "   ⚠ Could not read burst limit from nginx config"
    WARNINGS=$((WARNINGS + 1))
fi

# Summary
echo ""
echo "============================================"
echo "Verification Summary"
echo "============================================"
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "✓ All checks passed! Deployment successful."
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo "⚠ $WARNINGS warning(s). Deployment mostly successful but review warnings."
    exit 0
else
    echo "✗ $ERRORS error(s), $WARNINGS warning(s). Please resolve issues."
    exit 1
fi
