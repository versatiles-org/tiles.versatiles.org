#!/bin/sh
set -x
cd /var/www/tiles.versatiles.org/
git pull -f
nginx -s reload
