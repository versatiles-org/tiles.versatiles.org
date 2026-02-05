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

# Copy the newly renewed certificates to the nginx directory
cp -LfR ./volumes/certbot-cert/live/"${DOMAIN_NAME}" ./volumes/nginx-cert/live/

# Reload nginx to apply the new certificates
docker compose exec nginx nginx -s reload

echo "Certificate renewal and nginx reload completed successfully."
