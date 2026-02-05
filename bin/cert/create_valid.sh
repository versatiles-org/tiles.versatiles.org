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

# Reload nginx to apply the new certificates using Docker Compose
docker compose exec nginx nginx -s reload

# Set up weekly certificate renewal cron job if not already configured
PROJECT_DIR="$(pwd)"
CRON_CMD="0 3 * * 0 cd ${PROJECT_DIR} && ./bin/cert/renewal.sh >> /var/log/cert-renewal.log 2>&1"
if ! crontab -l 2>/dev/null | grep -q "bin/cert/renewal.sh"; then
    (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
    echo "Certificate renewal cron job added (weekly on Sundays at 3am)"
else
    echo "Certificate renewal cron job already configured"
fi

echo "Valid certificate created for ${DOMAIN}"
