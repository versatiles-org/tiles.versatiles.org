#!/usr/bin/env bash
set -euo pipefail

# Sets up a daily cron job (4:30am) that rolls out a new nginx image, see
# bin/nginx/update.sh. 4:30 keeps clear of the certificate renewal (Sundays at
# 3am), which reloads nginx without taking the deploy lock.
# Can be run independently or is called by bin/deploy/ensure.sh.

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."

PROJECT_DIR="$(pwd)"
CRON_CMD="30 4 * * * cd '${PROJECT_DIR}' && ./bin/cron/run.sh nginx-update 86400 ./bin/nginx/update.sh >> /var/log/nginx-update.log 2>&1"

if crontab -l 2>/dev/null | grep -qxF "$CRON_CMD"; then
    echo "nginx update cron job already configured"
else
    # Replace any existing entry (e.g. one pointing to an old project path)
    (crontab -l 2>/dev/null | grep -v "bin/nginx/update.sh" || true; echo "$CRON_CMD") | crontab -
    echo "nginx update cron job set (daily at 4:30am) for ${PROJECT_DIR}"
fi
