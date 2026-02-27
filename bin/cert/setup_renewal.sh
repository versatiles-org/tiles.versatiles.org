#!/usr/bin/env bash
set -euo pipefail

# Sets up a weekly cron job (Sundays at 3am) to renew SSL certificates.
# Can be run independently or is called by create_valid.sh.

# Navigate to the project's root directory relative to this script
cd "$(dirname "$0")/../.."

PROJECT_DIR="$(pwd)"
CRON_CMD="0 3 * * 0 cd '${PROJECT_DIR}' && ./bin/cert/renew.sh >> /var/log/cert-renewal.log 2>&1"

if ! crontab -l 2>/dev/null | grep -q "bin/cert/renew.sh"; then
    (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
    echo "Certificate renewal cron job added (weekly on Sundays at 3am)"
else
    echo "Certificate renewal cron job already configured"
fi
