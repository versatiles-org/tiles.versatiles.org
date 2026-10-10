#!/usr/bin/env bash
set -euo pipefail

# Sets up the cron jobs for bin/log/rotate.sh:
#   - on the 1st of each month at 00:05: rotate all nginx logs into monthly
#     archives and delete archives older than the retention period;
#   - every night at 00:10: rotate (and thereby anonymise) the nginx error log.
# Can be run again at any time; bin/deploy/ensure.sh does so on every update.

cd "$(dirname "$0")/../.."

PROJECT_DIR="$(pwd)"
LOG_FILE="/var/log/nginx-log-rotation.log"
CRON_MONTHLY="5 0 1 * * cd '${PROJECT_DIR}' && ./bin/log/rotate.sh >> ${LOG_FILE} 2>&1"
CRON_NIGHTLY="10 0 * * * cd '${PROJECT_DIR}' && ./bin/log/rotate.sh --error-log-only >> ${LOG_FILE} 2>&1"

CURRENT=$(crontab -l 2>/dev/null || true)

if echo "$CURRENT" | grep -qxF "$CRON_MONTHLY" && echo "$CURRENT" | grep -qxF "$CRON_NIGHTLY" \
    && [ "$(echo "$CURRENT" | grep -c "bin/log/rotate.sh")" = "2" ]; then
    echo "Log rotation cron jobs already configured"
else
    # Replace every existing rotation entry (an older schedule, or one pointing
    # at a previous location of this repository) with the two current ones.
    {
        if [ -n "$CURRENT" ]; then
            echo "$CURRENT" | grep -v "bin/log/rotate.sh" || true
        fi
        echo "$CRON_MONTHLY"
        echo "$CRON_NIGHTLY"
    } | crontab -
    echo "Log rotation cron jobs set (monthly on the 1st at 00:05; error log nightly at 00:10) for ${PROJECT_DIR}"
fi
