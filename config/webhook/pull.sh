#!/bin/sh
git pull -fq
nginx -s reload
supervisorctl reload
