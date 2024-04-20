#!/usr/bin/env bash
cd $(dirname "$0")/..

mkdir -p volumes

echo "prepare cert"
./bin/cert/create_dummy.sh

echo "init ramdisk"
./bin/ramdisk/init.sh

echo "fetch data"
./bin/data/update.sh

echo "start docker compose"
docker compose up --detach --force-recreate

echo "init letsencrypt"
./bin/cert/create_valid.sh
