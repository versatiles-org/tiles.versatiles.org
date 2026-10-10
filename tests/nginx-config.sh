#!/usr/bin/env bash
set -euo pipefail

# Checks that the nginx configuration of this repository loads: the template is
# rendered and tested with `nginx -t`, in the same nginx image and with the same
# mounts as in compose.yaml. Starts no server and needs no network.
#
# Usage: tests/nginx-config.sh
# Run by CI (.github/workflows/ci.yml); run it locally before changing anything
# under nginx/.

cd "$(dirname "$0")/.."

DOMAIN=tiles.example.org

# The nginx image compose.yaml pins (compose only needs the two variables to
# be set to something).
NGINX_IMAGE=$(DOMAIN_NAME="$DOMAIN" RAM_DISK_GB=4 docker compose config --images | grep -E '^nginx:')
echo "Testing the nginx config with $NGINX_IMAGE"

# A throwaway self-signed certificate where nginx expects the real one.
CERT_DIR=$(mktemp -d)
trap 'rm -rf "$CERT_DIR"' EXIT
mkdir -p "$CERT_DIR/live/$DOMAIN"
openssl req -nodes -new -x509 -subj "/CN=$DOMAIN" \
    -keyout "$CERT_DIR/live/$DOMAIN/privkey.pem" \
    -out "$CERT_DIR/live/$DOMAIN/fullchain.pem" 2>/dev/null
chmod -R a+rX "$CERT_DIR"

# The image's entrypoint renders the template (as at a real container start),
# then `nginx -t` loads the result.
#   --add-host   the config names the tile server `versatiles`; there is none here
#   --tmpfs      the cache directory, a RAM disk in production
docker run --rm \
    --add-host versatiles:127.0.0.1 \
    --tmpfs /data/nginx/cache \
    -e "DOMAIN_NAME=$DOMAIN" \
    -e RAM_DISK_GB=4 \
    -v "$PWD/nginx/nginx.stub.conf:/etc/nginx/nginx.conf:ro" \
    -v "$PWD/nginx/:/etc/nginx/repo/:ro" \
    -v "$PWD/nginx/templates/:/etc/nginx/templates/:ro" \
    -v "$PWD/nginx/docker-entrypoint.d/10-compute-cache-size.envsh:/docker-entrypoint.d/10-compute-cache-size.envsh:ro" \
    -v "$CERT_DIR:/etc/nginx/ssl/:ro" \
    "$NGINX_IMAGE" nginx -t

echo "nginx config OK"
