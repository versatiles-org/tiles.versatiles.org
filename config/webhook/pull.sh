#!/bin/sh
set -x
cd /var/www/tiles.versatiles.org/
git pull -f
wget -q "https://github.com/versatiles-org/versatiles-frontend/releases/latest/download/frontend.br.tar" -O /var/www/data/frontend.br.tar
#rm -r /var/www/ramdisk/*
nginx -s reload
