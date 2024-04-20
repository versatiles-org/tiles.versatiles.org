#!/usr/bin/env bash
cd $(dirname "$0")/../..
. .env

docker compose exec certbot renew
cp -LfR ./volumes/certbot-cert/live/${DOMAIN_NAME} ./volumes/nginx-cert/live/
docker compose exec nginx nginx -s reload

