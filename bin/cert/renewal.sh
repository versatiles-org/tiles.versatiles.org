#!/usr/bin/env bash

docker compose -f compose.yaml up certbot
docker compose -f compose.yaml exec nginx nginx -s reload
