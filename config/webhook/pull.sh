#!/bin/sh
git pull -f
npm ci
npm run start /var/www/docs
nginx -s reload
