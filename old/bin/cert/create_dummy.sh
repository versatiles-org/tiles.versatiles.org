#!/usr/bin/env bash

# This script create a dummy SSL certificate using OpenSSL for nginx

# Navigate to the project's root directory based on this script's location
cd "$(dirname "$0")/../.."

# Load environment variables from the .env file
source .env

# Create the directory structure for storing nginx SSL certificates, ensuring it doesn't fail if it already exists
mkdir -p "./volumes/nginx-cert/live/${DOMAIN_NAME}/"

# Generate a new self-signed SSL certificate and private key for the domain
openssl req -nodes -new -x509 -subj "/CN=localhost" -keyout "./volumes/nginx-cert/live/${DOMAIN_NAME}/privkey.pem" -out "./volumes/nginx-cert/live/${DOMAIN_NAME}/fullchain.pem"

# Schedule a weekly cron job for automatic certificate renewal
echo "23 5 * * 1 $(pwd)/bin/cert/renewal.sh" | crontab -
