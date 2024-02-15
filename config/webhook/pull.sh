#!/bin/sh
cd /var/www/tiles.versatiles.org/
git pull -fq
nginx -s reload
supervisorctl reload
