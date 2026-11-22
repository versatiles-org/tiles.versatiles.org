#!/usr/bin/env bash
set -euo pipefail

# Sets up the cron job for bin/log/rotate.sh: every night at 00:10, rotate the
# nginx logs into their archives (the referer statistics on the 1st of each
# month only) and delete access and error log archives older than 28 days.
# Can be run again at any time; bin/deploy/ensure.sh does so on every update.

cd "$(dirname "$0")/../.."

PROJECT_DIR="$(pwd)"
LOG_FILE="/var/log/nginx-log-rotation.log"
CRON_NIGHTLY="10 0 * * * cd '${PROJECT_DIR}' && ./bin/log/rotate.sh >> ${LOG_FILE} 2>&1"

CURRENT=$(crontab -l 2>/dev/null || true)

if echo "$CURRENT" | grep -qxF "$CRON_NIGHTLY" \
    && [ "$(echo "$CURRENT" | grep -c "bin/log/rotate.sh")" = "1" ]; then
    echo "Log rotation cron job already configured"
else
    # Replace every existing rotation entry (an older schedule, or one pointing
    # at a previous location of this repository) with the current one.
    {
        if [ -n "$CURRENT" ]; then
            echo "$CURRENT" | grep -v "bin/log/rotate.sh" || true
        fi
        echo "$CRON_NIGHTLY"
    } | crontab -
    echo "Log rotation cron job set (nightly at 00:10) for ${PROJECT_DIR}"
fi
