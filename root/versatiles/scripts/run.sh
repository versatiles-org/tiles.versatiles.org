#!/bin/bash

cd "$(dirname "$0")"

# Exit immediately if a command exits with a non-zero status
set -e

bash update_frontend.sh
bash update_mapdata.sh
bash /scripts/start_nginx_certbot.sh
