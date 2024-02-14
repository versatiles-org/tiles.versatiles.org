#!/bin/bash
cd "$(dirname "$0")"
set -e

NAME="tiles.versatiles.org"
hcloud server create --location nbg1 --image debian-12 --type cax21 --name $NAME --network tiles.versatiles.org --ssh-key 9919841
sleep 30
echo "SECRET=\"$(cat secret.txt)\"" | cat - scripts/setup_server.sh | hcloud server ssh $NAME
hcloud load-balancer add-target tiles.versatiles.org --server $NAME --use-private-ip
