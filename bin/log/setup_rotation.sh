#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT_DIR="$(pwd)"
CRON_CMD="0 2 1 * * cd '${PROJECT_DIR}' && ./bin/log/rotate.sh >> /var/log/nginx-log-rotation.log 2>&1"

if ! crontab -l 2>/dev/null | grep -q "bin/log/rotate.sh"; then
    (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
    echo "Log rotation cron job added (monthly on 1st at 2am)"
else
    echo "Log rotation cron job already configured"
fi
