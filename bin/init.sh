#!/usr/bin/env bash
cd $(dirname "$0")/..

mkdir -p volumes

echo "init letsencrypt"
./bin/cert/init.sh

echo "init ramdisk"
./bin/ramdisk/init.sh

echo "fetch data"
./bin/data/update.sh

echo "start docker compose"
docker compose up --detach --force-recreate

echo "generate a new key"
./bin/cert/renewal.sh
