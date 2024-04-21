#!/usr/bin/env bash
cd $(dirname "$0")/../..
. .env

mkdir -p volumes/versatiles



# download planet
if [ -z $BBOX ]; then
	docker compose exec versatiles bash -c "wget --progress=dot:giga 'https://download.versatiles.org/osm.versatiles' -O /data/temp.versatiles; mv /data/temp.versatiles /data/osm.versatiles"
else
	docker compose exec versatiles bash -c "versatiles convert --bbox '$BBOX' --bbox-border 3 'https://download.versatiles.org/osm.versatiles' /data/temp.versatiles; mv /data/temp.versatiles /data/osm.versatiles"
fi



# download frontend
wget --no-verbose --progress=dot:giga "https://github.com/versatiles-org/versatiles-frontend/releases/latest/download/frontend.br.tar" -O volumes/versatiles/frontend.br.tar



# add frontend patch
rm -rf ./volumes/versatiles/static
cp -r ./static ./volumes/versatiles/


