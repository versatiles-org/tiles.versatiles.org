#!/usr/bin/env bash
cd $(dirname "$0")/../..
. .env

rm -r volumes/cache/*
docker-compose -f compose.yaml exec nginx nginx -s reload
