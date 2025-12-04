#!/usr/bin/env bash

# This script renews SSL certificates using Certbot within a Docker environment,
# then copies the new certificates to the nginx directory and reloads nginx.

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."

# Load environment variables from the .env file
source .env

# Use Docker Compose to execute the Certbot 'renew' command in the 'certbot' service container
docker compose run --rm certbot renew
if [ $? -ne 0 ]; then
   echo "Failed to renew certificates with Certbot."
   exit 1
fi

# Copy the newly renewed certificates to the nginx directory
cp -LfR ./volumes/certbot-cert/live/"${DOMAIN_NAME}" ./volumes/nginx-cert/live/
if [ $? -ne 0 ]; then
   echo "Failed to copy new certificates to nginx directory."
   exit 1
fi

# Reload nginx to apply the new certificates
docker compose exec nginx nginx -s reload
if [ $? -ne 0 ]; then
   echo "Failed to reload nginx. Please check the configuration."
   exit 1
fi

echo "Certificate renewal and nginx reload completed successfully."
