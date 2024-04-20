#!/usr/bin/env bash
cd $(dirname "$0")/..

git pull

echo "fetch data"
./bin/data/update.sh

echo "clear cache data"
./bin/ramdisk/clear.sh

echo "restart docker compose"
docker compose up --force-recreate
