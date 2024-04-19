#!/usr/bin/env bash
cd $(dirname "$0")/..

mkdir -p volumes
# init letsencrypt
./bin/cert/init.sh
# TODO: add cronjob for renewal
# TODO: init ramdisk

mkdir -p volumes/versatiles
# download planet
wget --progress=dot:giga "https://download.versatiles.org/osm.versatiles" -O volumes/versatiles/osm.versatiles
# download frontend
wget --progress=dot:giga "https://github.com/versatiles-org/versatiles-frontend/releases/latest/download/frontend.br.tar" -O volumes/versatiles/frontend.br.tar
# copy frontend patch
cp -R static volumes/versatiles/

# start docker compose
docker compose up --force-recreate

./bin/cert/renewal.sh
