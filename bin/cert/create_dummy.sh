#!/usr/bin/env bash
cd $(dirname "$0")/../..
. .env

mkdir -p ./volumes/nginx-cert/live/${DOMAIN_NAME}/

openssl req -nodes -new -x509 -subj "/CN=localhost" \
   -keyout ./volumes/nginx-cert/live/${DOMAIN_NAME}/privkey.pem \
	-out ./volumes/nginx-cert/live/${DOMAIN_NAME}/fullchain.pem

# add cronjob for renewal
crontab -l | { cat; echo "0 5 * * 1 $(pwd)/bin/cert/renewal.sh"; } | crontab -
