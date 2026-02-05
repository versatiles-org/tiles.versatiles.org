#!/usr/bin/env bash
set -euo pipefail

# This script renews SSL certificates using Certbot within a Docker environment,
# then copies the new certificates to the nginx directory and reloads nginx.

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."

# Load environment variables from the .env file
source .env

# Use Docker Compose to execute the Certbot 'renew' command in the 'certbot' service container
docker compose run --rm certbot renew

# Copy the newly renewed certificates to the nginx directory for both domains
if [ -d "./volumes/certbot-cert/live/${DOMAIN_NAME}" ]; then
    cp -LfR ./volumes/certbot-cert/live/"${DOMAIN_NAME}" ./volumes/nginx-cert/live/
fi
if [ -d "./volumes/certbot-cert/live/${DOWNLOAD_DOMAIN}" ]; then
    cp -LfR ./volumes/certbot-cert/live/"${DOWNLOAD_DOMAIN}" ./volumes/nginx-cert/live/
fi

# Reload nginx to apply the new certificates
docker compose exec nginx nginx -s reload

echo "Certificate renewal and nginx reload completed successfully."
