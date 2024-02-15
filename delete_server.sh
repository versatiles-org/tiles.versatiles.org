#!/bin/bash
cd "$(dirname "$0")"
set -e

NAME="download.versatiles.org"
sed -i '' -e '/116\.203\.184\.248/d' ~/.ssh/known_hosts
hcloud volume detach download.versatiles.org
hcloud server delete $NAME
