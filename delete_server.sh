#!/bin/bash
cd "$(dirname "$0")"
set -e

NAME="download.versatiles.org"
sed -i '' -e '/128\.140\.47\.180/d' ~/.ssh/known_hosts
hcloud volume detach download.versatiles.org
hcloud server delete $NAME
