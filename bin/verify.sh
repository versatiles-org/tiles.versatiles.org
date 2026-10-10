#!/usr/bin/env bash
set -euo pipefail

# Post-deployment verification for tiles.versatiles.org.
# Run this AFTER a deployment; ./bin/update.sh and ./bin/deploy/setup.sh run it
# as their last step.
#
# It checks the server the way a client sees it — over the public domain — plus
# the local setup the deployment depends on.
#
#   ✗ error    something a client would notice, or that will break soon
#              (a tileset not served, a certificate about to expire, …).
#              The script exits 1.
#   ⚠ warning  something to look at that does not affect clients right now
#              (a missing cron job, a dummy certificate on a test box, …).
#              The script still exits 0.

cd "$(dirname "$0")/.."

source .env
source bin/deploy/helpers.sh

echo "============================================"
echo "Post-Deployment Verification"
echo "============================================"
echo ""

ERRORS=0
WARNINGS=0

pass() { echo -e "   \033[0;32m✓ $*\033[0m"; }
fail() { echo -e "   \033[0;31m✗ $*\033[0m"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "   \033[0;33m⚠ $*\033[0m"; WARNINGS=$((WARNINGS + 1)); }

BASE="https://${DOMAIN_NAME}"

# Extra curl options for every HTTPS request. Stays empty when the certificate
# is a real one, so TLS is verified like a browser would; set to -k in step 3
# when only the dummy certificate from setup is in place.
CURL_TLS=()

# http_status <url> [curl options…] → prints the HTTP status ("000" if the
# request failed altogether).
http_status() {
    local url="$1"
    shift
    curl -s -o /dev/null --max-time 30 -w '%{http_code}' ${CURL_TLS[@]+"${CURL_TLS[@]}"} "$@" "$url" 2>/dev/null || true
}

# http_headers <url> [curl options…] → prints the status line and response
# headers, without carriage returns. Header names may be in any case (HTTP/2
# sends them lower-cased), so match them with `grep -i`.
http_headers() {
    local url="$1"
    shift
    curl -s -o /dev/null --max-time 30 -D - ${CURL_TLS[@]+"${CURL_TLS[@]}"} "$@" "$url" 2>/dev/null | tr -d '\r' || true
}

# header_value <headers> <name> → prints the value of the first header with that name.
header_value() {
    echo "$1" | grep -i "^$2:" | head -n 1 | cut -d' ' -f2- || true
}

# expect_200 <label> <path>
expect_200() {
    local code
    code=$(http_status "${BASE}$2")
    if [ "$code" = "200" ]; then
        pass "$1"
    else
        fail "$1 — ${BASE}$2 returned $code (expected 200)"
    fi
}

# -----------------------------------------------------------------------------
echo "1. Checking Docker services..."
for service in versatiles nginx; do
    if service_is_running "$service"; then
        pass "$service is running"
    else
        fail "$service is NOT running"
    fi
done

# A second tile server container exists only for a moment while one is being
# replaced (replace_tile_server). One left behind means a replacement was
# interrupted.
TILE_SERVERS=$(docker compose ps -q versatiles 2>/dev/null | grep -c . || true)
if [ "$TILE_SERVERS" -gt 1 ]; then
    warn "$TILE_SERVERS tile server containers are running (expected 1)"
    echo "     → An interrupted replacement? Check 'docker compose ps', then run: ./bin/restart.sh"
fi

for service in versatiles nginx; do
    if service_has_pending_change "$service"; then
        warn "$service container is out of date (new image or changed compose definition)"
        echo "     → Run: ./bin/update.sh"
    fi
done

# -----------------------------------------------------------------------------
echo ""
echo "2. Checking nginx configuration..."
if docker compose exec -T nginx nginx -t &> /dev/null; then
    pass "Nginx configuration is valid"
else
    fail "Nginx configuration is invalid"
    docker compose exec -T nginx nginx -t 2>&1 | head -5 || true
fi

# -----------------------------------------------------------------------------
echo ""
echo "3. Checking SSL certificate..."
CERT_PATH="./volumes/nginx-cert/live/${DOMAIN_NAME}/fullchain.pem"
CERT_MIN_DAYS=14
if [ -f "$CERT_PATH" ]; then
    ISSUER=$(openssl x509 -in "$CERT_PATH" -noout -issuer 2>/dev/null || echo "")
    if echo "$ISSUER" | grep -qi "Let's Encrypt"; then
        EXPIRY=$(openssl x509 -in "$CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)
        # Certificates are renewed by a weekly cron job once they have 30 days
        # left. Less than $CERT_MIN_DAYS days means renewal has been failing for
        # a while — and nobody else will tell: Let's Encrypt no longer sends
        # expiry e-mails.
        if openssl x509 -in "$CERT_PATH" -noout -checkend $((CERT_MIN_DAYS * 86400)) >/dev/null 2>&1; then
            pass "${DOMAIN_NAME} has a Let's Encrypt certificate (expires: $EXPIRY)"
        else
            fail "${DOMAIN_NAME} certificate expires in less than ${CERT_MIN_DAYS} days ($EXPIRY) — renewal is not working"
            echo "     → Run: ./bin/cert/renew.sh   and check /var/log/cert-renewal.log"
        fi
    else
        warn "${DOMAIN_NAME} has a dummy/self-signed certificate — TLS is not verified in the checks below"
        echo "     → Run: ./bin/cert/create_valid.sh ${DOMAIN_NAME}"
        CURL_TLS=(-k)
    fi
else
    fail "${DOMAIN_NAME} certificate not found"
    CURL_TLS=(-k)
fi

# -----------------------------------------------------------------------------
echo ""
echo "4. Testing HTTP and HTTPS on ${DOMAIN_NAME}..."
HTTP_CODE=$(curl -s -o /dev/null --max-time 30 -w '%{http_code}' "http://${DOMAIN_NAME}/" 2>/dev/null || true)
if [ "$HTTP_CODE" = "301" ]; then
    pass "HTTP redirects to HTTPS (301)"
else
    fail "HTTP returned $HTTP_CODE (expected 301)"
fi

# Without -k (unless only the dummy certificate exists): this also fails when
# the certificate nginx serves is expired or does not match the domain.
expect_200 "HTTPS start page" "/"

# -----------------------------------------------------------------------------
echo ""
echo "5. Testing tilesets..."
# The tilesets to expect are the ones the update pipeline is configured to serve.
TILESETS=$(python3 -c 'import json; print(" ".join(d["name"] for d in json.load(open("download/sources.json"))))' 2>/dev/null || echo "")
if [ -z "$TILESETS" ]; then
    fail "Could not read the tileset names from download/sources.json"
fi
for tileset in $TILESETS; do
    TILE_CODE=$(http_status "${BASE}/tiles/${tileset}/0/0/0")
    JSON_CODE=$(http_status "${BASE}/tiles/${tileset}/tiles.json")
    if [ "$TILE_CODE" = "200" ] && [ "$JSON_CODE" = "200" ]; then
        pass "${tileset}: tile and TileJSON served"
    else
        fail "${tileset}: tile 0/0/0 returned $TILE_CODE, tiles.json returned $JSON_CODE (expected 200)"
    fi
done

# Satellite is the one tileset stacked from two sources: low zoom levels from
# local disk, high zoom levels straight from the CDN. Tile 0/0/0 only proves
# the first half.
case " $TILESETS " in
    *" satellite "*) expect_200 "satellite: high zoom level (read from the CDN)" "/tiles/satellite/17/70406/42987" ;;
esac

# -----------------------------------------------------------------------------
echo ""
echo "6. Testing frontend and assets..."
STYLE_URL="${BASE}/assets/styles/colorful/style.json"
if curl -s --max-time 30 ${CURL_TLS[@]+"${CURL_TLS[@]}"} "$STYLE_URL" 2>/dev/null | python3 -m json.tool >/dev/null 2>&1; then
    pass "Style JSON is valid"
else
    fail "Style JSON is invalid or missing ($STYLE_URL)"
fi
expect_200 "MapLibre GL JS"  "/assets/lib/maplibre-gl/maplibre-gl.js"
expect_200 "Font list"       "/assets/glyphs/index.json"
expect_200 "Glyphs"          "/assets/glyphs/noto_sans_regular/0-255.pbf"
expect_200 "Sprite sheet"    "/assets/sprites/base.json"

# -----------------------------------------------------------------------------
echo ""
echo "7. Checking CORS headers..."
# Maps on other websites load all of these cross-origin. The path must answer
# 200 as well: nginx adds the CORS header to error responses too, so the header
# alone proves nothing.
CORS_PATHS=(
    "/tiles/osm/0/0/0"
    "/assets/styles/colorful/style.json"
    "/assets/sprites/base.json"
    "/assets/glyphs/index.json"
)
for path in "${CORS_PATHS[@]}"; do
    HEADERS=$(http_headers "${BASE}${path}" -H "Origin: https://example.com")
    STATUS=$(echo "$HEADERS" | head -n 1)
    if echo "$STATUS" | grep -q " 200" && [ "$(header_value "$HEADERS" access-control-allow-origin)" = "*" ]; then
        pass "CORS header present on ${path}"
    else
        fail "CORS check failed on ${path} (status line: ${STATUS:-none})"
    fi
done

# -----------------------------------------------------------------------------
echo ""
echo "8. Checking caching..."
TILE_URL="${BASE}/tiles/osm/0/0/0"
HEADERS=$(http_headers "$TILE_URL")

# One Cache-Control header, the 6-hour policy set in proxy.conf.template.
CC_COUNT=$(echo "$HEADERS" | grep -ci "^cache-control:" || true)
TILE_CC=$(header_value "$HEADERS" cache-control)
if [ "$CC_COUNT" = "1" ] && [ "$TILE_CC" = "public, max-age=21600, no-transform" ]; then
    pass "Tiles are cacheable for 6 hours"
else
    fail "Unexpected Cache-Control on a tile ($CC_COUNT header(s), first: ${TILE_CC:-none})"
fi

# Revalidation: a client that sends back the ETag gets an empty 304.
ETAG=$(header_value "$HEADERS" etag)
if [ -n "$ETAG" ]; then
    REVAL_CODE=$(http_status "$TILE_URL" -H "If-None-Match: $ETAG")
    if [ "$REVAL_CODE" = "304" ]; then
        pass "Tiles carry an ETag and revalidate with 304"
    else
        fail "A matching If-None-Match returned $REVAL_CODE (expected 304)"
    fi
else
    fail "Tiles carry no ETag"
fi

# Errors must not be cacheable for hours: a missing tile briefly, anything else
# not at all.
MISSING_CC=$(header_value "$(http_headers "${BASE}/tiles/osm/15/0/0")" cache-control)
if [ "$MISSING_CC" = "public, max-age=300" ]; then
    pass "A missing tile (404) is cacheable for 5 minutes only"
else
    fail "Unexpected Cache-Control on a missing tile (${MISSING_CC:-none})"
fi

# -----------------------------------------------------------------------------
echo ""
echo "9. Checking legacy redirects..."
# Old URLs that are redirected in proxy.conf.template. Each must end in a 200 —
# a redirect to a path that no longer exists is worse than a plain 404.
LEGACY_PATHS=(
    "/maplibre/maplibre-gl.js"
    "/assets/maplibre/maplibre-gl.js"
    "/fonts.json"
    "/fonts/noto_sans_regular/0-255.pbf"
    "/assets/fonts/noto_sans_regular/0-255.pbf"
    "/sprites.json"
    "/styles/colorful/style.json"
    "/assets/styles/eclipse/style.json"
    "/assets/styles/satellite/nooverlay.json"
)
for path in "${LEGACY_PATHS[@]}"; do
    FIRST=$(http_status "${BASE}${path}")
    FINAL=$(http_status "${BASE}${path}" -L)
    if [ "$FIRST" = "301" ] && [ "$FINAL" = "200" ]; then
        pass "${path} redirects to an existing file"
    else
        fail "${path}: returned $FIRST, ends in $FINAL after following redirects (expected 301, then 200)"
    fi
done

# -----------------------------------------------------------------------------
echo ""
echo "10. Checking cron jobs..."
if crontab -l 2>/dev/null | grep -q "bin/cert/renew.sh"; then
    pass "Certificate renewal cron job is configured"
else
    warn "Certificate renewal cron job not found"
    echo "     → Run: ./bin/cert/setup_renewal.sh"
fi

if crontab -l 2>/dev/null | grep -q "bin/log/rotate.sh"; then
    pass "Log rotation cron job is configured"
else
    warn "Log rotation cron job not found"
    echo "     → Run: ./bin/log/setup_rotation.sh"
fi

# -----------------------------------------------------------------------------
echo ""
echo "11. Checking volume directories..."
# Tile data dir is relocatable via TILES_DIR in .env (default ./volumes/tiles).
TILES_DIR="${TILES_DIR:-./volumes/tiles}"
VOLUME_DIRS="$TILES_DIR volumes/frontend volumes/cache volumes/certbot-cert volumes/certbot-www volumes/nginx-cert volumes/nginx-log volumes/versatiles_conf"
for dir in $VOLUME_DIRS; do
    if [ -d "$dir" ]; then
        pass "$dir exists"
    else
        fail "$dir is missing"
    fi
done

# Check updater-written volumes are writable by UID 1001
for dir in "$TILES_DIR" volumes/versatiles_conf; do
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

# -----------------------------------------------------------------------------
echo ""
echo "12. Checking nginx rate limit configuration..."
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

# -----------------------------------------------------------------------------
echo ""
echo "============================================"
echo "Verification Summary"
echo "============================================"
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "\033[0;32m✓ All checks passed! Deployment successful.\033[0m"
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo -e "\033[0;33m⚠ $WARNINGS warning(s). Nothing a client would notice, but review them.\033[0m"
    exit 0
else
    echo -e "\033[0;31m✗ $ERRORS error(s), $WARNINGS warning(s). Please resolve issues.\033[0m"
    exit 1
fi
