#!/bin/bash
set -e
cd "$(dirname $0)/.."

mkdir -p volumes/data
mkdir -p volumes/www

docker run \
	--env "USE_LOCAL_CA=1" \
	--env-file .env \
	--expose 80,443 \
	--mount type=tmpfs,tmpfs-size=4GB,target=/versatiles/cache \
	--mount type=bind,source="$(pwd)"/volumes/data,target=/versatiles/data \
	--mount type=bind,source="$(pwd)"/volumes/www,target=/versatiles/www \
	--name versatiles-nginx \
	--rm \
	versatiles-nginx
