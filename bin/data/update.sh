#!/usr/bin/env bash
cd $(dirname "$0")/../..
. .env

mkdir -p volumes/versatiles



# download planet
if [ -z $BBOX ]; then
	wget --progress=dot:giga "https://download.versatiles.org/osm.versatiles" -O volumes/osm.versatiles
else
	versatiles convert --bbox "$BBOX" --bbox-border 3 "https://download.versatiles.org/osm.versatiles" volumes/osm.versatiles
fi
mv -f volumes/osm.versatiles volumes/versatiles/



# download frontend
wget --no-verbose --progress=dot:giga "https://github.com/versatiles-org/versatiles-frontend/releases/latest/download/frontend.br.tar" -O volumes/versatiles/frontend.br.tar



# add frontend patch
rm -rf ./volumes/versatiles/static
cp -r ./static ./volumes/versatiles/


