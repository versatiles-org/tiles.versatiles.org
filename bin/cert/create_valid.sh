#!/usr/bin/env bash
set -euo pipefail

# This script initiates the generation of SSL certificates using Certbot within a Docker environment,
# copies the generated certificates to the nginx directory, and then reloads nginx to apply changes.
# Usage: ./create_valid.sh [domain]
# If no domain is provided, uses DOMAIN_NAME from .env

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."

# Load environment variables from the .env file
source .env

# Use provided domain or default to DOMAIN_NAME from .env
DOMAIN="${1:-$DOMAIN_NAME}"

echo "Creating valid certificate for ${DOMAIN}..."

# Use Docker Compose to run certbot to obtain or renew a certificate
docker compose run --rm certbot certonly --force-renewal --webroot --webroot-path=/var/www/certbot --email "${EMAIL}" --agree-tos --no-eff-email -d "${DOMAIN}"

# Ensure the directories exist and copy the newly acquired or renewed certificate to the nginx directory
mkdir -p ./volumes/nginx-cert/live/"${DOMAIN}"
cp -LfR ./volumes/certbot-cert/live/"${DOMAIN}" ./volumes/nginx-cert/live/

if [ ! -f "./volumes/nginx-cert/live/${DOMAIN}/fullchain.pem" ]; then
	echo "Error: Certificate copy failed for ${DOMAIN}"
	exit 1
fi

# Reload nginx to apply the new certificates using Docker Compose
docker compose exec nginx nginx -s reload

# Set up certificate renewal cron job
./bin/cert/setup_renewal.sh

echo "Valid certificate created for ${DOMAIN}"
