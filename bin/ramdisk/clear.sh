#!/usr/bin/env bash
cd $(dirname "$0")/../..
. .env

rm -rf ./volumes/cache/*
docker compose exec nginx nginx -s reload
