#!/usr/bin/env bash
cd $(dirname "$0")/../..

. .env

mkdir -p ./volumes/letsencrypt/live/${DOMAIN_NAME}/

openssl req -quiet -nodes -new -x509 -subj "/CN=localhost" \
   -keyout ./volumes/letsencrypt/live/${DOMAIN_NAME}/privkey.pem \
	-out ./volumes/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem
