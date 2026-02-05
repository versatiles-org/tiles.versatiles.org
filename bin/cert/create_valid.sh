#!/usr/bin/env bash
set -euo pipefail

# This script initiates the generation of SSL certificates using Certbot within a Docker environment,
# copies the generated certificates to the nginx directory, and then reloads nginx to apply changes.

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."

# Load environment variables from the .env file
source .env

# Use Docker Compose to run certbot to obtain or renew a certificate
docker compose run certbot certonly --force-renewal --webroot --webroot-path=/var/www/certbot --email "${EMAIL}" --agree-tos --no-eff-email -d "${DOMAIN_NAME}"

# Ensure the directories exist and copy the newly acquired or renewed certificate to the nginx directory
mkdir -p ./volumes/nginx-cert/live/"${DOMAIN_NAME}"
cp -LfR ./volumes/certbot-cert/live/"${DOMAIN_NAME}" ./volumes/nginx-cert/live/

# Reload nginx to apply the new certificates using Docker Compose
docker compose exec nginx nginx -s reload
