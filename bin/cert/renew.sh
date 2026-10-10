#!/usr/bin/env bash
set -euo pipefail

# This script renews SSL certificates using Certbot within a Docker environment,
# then copies the new certificates to the nginx directory and reloads nginx.

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."

# Load environment variables from the .env file
source .env
source bin/deploy/helpers.sh

# certbot proves domain ownership through files that the running nginx serves
# from the shared certbot-www volume. Without nginx a renewal cannot succeed.
if ! service_is_running nginx; then
    echo "Error: nginx is not running — cannot renew certificates." >&2
    exit 1
fi

# Run certbot's 'renew' in a one-off container.
# --no-deps: do not let compose touch nginx or the tile server. Without it,
# `compose run` first brings the services certbot depends on in line with
# compose.yaml, recreating any whose image or config changed since it was
# started. This script runs unattended from cron, and that would roll out a
# pending image or config change at 3 a.m. — with the brief outage a recreate
# costs and without the cache clear and verification of ./bin/update.sh.
docker compose run --rm --no-deps certbot renew

# Copy the newly renewed certificate to the nginx directory
if [ -d "./volumes/certbot-cert/live/${DOMAIN_NAME}" ]; then
    cp -LfR ./volumes/certbot-cert/live/"${DOMAIN_NAME}" ./volumes/nginx-cert/live/
    if [ ! -f "./volumes/nginx-cert/live/${DOMAIN_NAME}/fullchain.pem" ]; then
        echo "Error: Certificate copy failed for ${DOMAIN_NAME}"
        exit 1
    fi
fi

# Reload nginx to apply the new certificates.
# Use -T: this script runs from cron (no TTY), and `docker compose exec` would
# otherwise try to allocate one and fail with "the input device is not a TTY",
# leaving the freshly renewed certificate unloaded.
docker compose exec -T nginx nginx -s reload

echo "Certificate renewal and nginx reload completed successfully."
