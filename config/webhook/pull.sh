#!/bin/sh
cd /var/www/tiles.versatiles.org/
git pull -f
nginx -s reload
supervisorctl reload
