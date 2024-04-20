#!/usr/bin/env bash
cd $(dirname "$0")/../..
. .env

docker compose run certbot certonly -v --force-renewal --webroot --webroot-path=/var/www/certbot --email ${EMAIL} --agree-tos --no-eff-email -d ${DOMAIN_NAME}
cp -LfR ./volumes/certbot-cert/live/${DOMAIN_NAME} ./volumes/nginx-cert/live/
docker compose exec nginx nginx -s reload
