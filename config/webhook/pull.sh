#!/bin/sh
git pull -f
nginx -s reload
supervisorctl reload
