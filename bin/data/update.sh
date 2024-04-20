#!/usr/bin/env bash
cd $(dirname "$0")/../..
. .env

mkdir -p volumes/versatiles

# download planet
URL="https://download.versatiles.org/osm.versatiles"
if [ -z $BBOX ]; then
	docker run versatiles/versatiles:latest-alpine versatiles convert --bbox "$BBOX" --bbox-border 3 "$URL" osm.versatiles
else
	wget --progress=dot:giga "$URL" -O osm.versatiles
fi
cp -f osm.versatiles volumes/versatiles/

# download frontend
wget --progress=dot:giga "https://github.com/versatiles-org/versatiles-frontend/releases/latest/download/frontend.br.tar" -O volumes/versatiles/frontend.br.tar

# add frontend patch
STATIC=./volumes/versatiles/static
if [ -L $STATIC ]; then
	echo "Link exists"
else
	if [ -e $STATIC ]; then
		echo "remove old link"
		rm $STATIC
	fi
	ln -s ./static $STATIC
fi


