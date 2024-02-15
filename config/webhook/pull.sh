#!/bin/sh
set -x
cd /var/www/tiles.versatiles.org/
git pull -f
rm -r /var/www/ramdisk/*
nginx -s reload
