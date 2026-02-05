#!/usr/bin/env bash
set -euo pipefail

# This script creates a dummy SSL certificate using OpenSSL for nginx
# Usage: ./create_dummy.sh [domain]
# If no domain is provided, uses DOMAIN_NAME from .env

# Navigate to the project's root directory based on this script's location
cd "$(dirname "$0")/../.."

# Load environment variables from the .env file
source .env

# Use provided domain or default to DOMAIN_NAME from .env
DOMAIN="${1:-$DOMAIN_NAME}"

# Create the directory structure for storing nginx SSL certificates, ensuring it doesn't fail if it already exists
mkdir -p "./volumes/nginx-cert/live/${DOMAIN}/"

# Generate a new self-signed SSL certificate and private key for the domain
openssl req -nodes -new -x509 -subj "/CN=${DOMAIN}" -keyout "./volumes/nginx-cert/live/${DOMAIN}/privkey.pem" -out "./volumes/nginx-cert/live/${DOMAIN}/fullchain.pem"

echo "Dummy certificate created for ${DOMAIN}"

# Schedule a weekly cron job for automatic certificate renewal (preserving existing jobs)
CRON_JOB="23 5 * * 1 $(pwd)/bin/cert/renewal.sh"
( crontab -l 2>/dev/null | grep -v "bin/cert/renewal.sh"; echo "$CRON_JOB" ) | crontab -
