#!/usr/bin/env bash
set -euo pipefail

# Rotates the nginx log files in volumes/nginx-log into one archive per month,
# and deletes archives that are older than the retention period.
#
# Usage:
#   rotate.sh                   Rotate all three logs and apply the retention.
#                               Run by cron in the first minutes of each month.
#   rotate.sh --error-log-only  Rotate only error.log. Run by cron every night.
#
# The live files and their monthly archives:
#   access.tsv.gz         → access.<YYYY-MM>.tsv.gz          requests that went wrong
#   referer_stats.tsv.gz  → referer_stats.<YYYY-MM>.tsv.gz   requests that were served
#   error.log             → error.<YYYY-MM>.log.gz           nginx's own error log
#
# A rotated log is APPENDED to the month's archive, never written over it. A
# gzip file may consist of several compressed parts in a row, so appending keeps
# the archive valid. That is what makes it safe to run this script more than
# once a month — by hand, or nightly for the error log.
#
# Why the error log is rotated every night: nginx writes it in a fixed format
# that includes the full client address and request line (the access logs do
# not, see nginx/templates/proxy.conf.template). It is anonymised here, when it
# is rotated — so the shorter the live file lives, the less it holds.
#
# The month in the archive name is yesterday's: the script runs just after
# midnight, and what it rotates was written before.

cd "$(dirname "$0")/../.."

LOG_DIR="./volumes/nginx-log"

# How many full months of access.* and error.* archives to keep. They exist for
# finding problems and contain (anonymised) client addresses and user agents.
# referer_stats.* archives are kept without limit: they hold no personal data
# and are what bin/log/monthly_traffic.sh builds its history from.
RETENTION_MONTHS=12

ERROR_LOG_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --error-log-only) ERROR_LOG_ONLY=true ;;
        -h|--help) sed -n '4,11p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; echo "Usage: $0 [--error-log-only]" >&2; exit 1 ;;
    esac
done

if [ "$ERROR_LOG_ONLY" = "true" ]; then
    LOGS=(error.log)
else
    LOGS=(access.tsv.gz referer_stats.tsv.gz error.log)
fi

MONTH=$(date -d "yesterday" +%Y-%m 2>/dev/null || date -v-1d +%Y-%m)

# Appends a log that nginx no longer writes to (<name>.rotating) to this month's
# archive, then removes it.
archive_rotated() {
    local log="$1"
    local rotating="$LOG_DIR/$log.rotating"
    [ -f "$rotating" ] || return 0

    if [ "$log" = "error.log" ]; then
        # Anonymise, then compress:
        #   - client address: last octet zeroed (IPv4) / cut to the first two
        #     groups (IPv6), the same rule as $remote_addr_anon in nginx.conf
        #   - request and upstream: query string removed
        #   - referrer: reduced to scheme://host
        # A typical line before:
        #   … client: 203.0.113.57, server: …, request: "GET /x?token=… HTTP/2.0",
        #   upstream: "http://…/x?token=…", referrer: "https://example.org/page?…"
        sed -E \
            -e 's/(client: [0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/\1.0/g' \
            -e 's/(client: [0-9a-fA-F]*:[0-9a-fA-F]*):[0-9a-fA-F:.]*/\1::/g' \
            -e 's/(request: "[A-Z]+ [^ ?"]*)\?[^ "]*/\1/g' \
            -e 's/(upstream: "[^"?]*)\?[^"]*/\1/g' \
            -e 's/(referrer: "[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\/?#"]*)[^"]*/\1/g' \
            "$rotating" | gzip >>"$LOG_DIR/error.${MONTH}.log.gz"
    else
        # Already gzip-compressed by nginx: insert the month before the first
        # extension (access.tsv.gz → access.2026-03.tsv.gz) and append as is.
        cat "$rotating" >>"$LOG_DIR/${log%%.*}.${MONTH}.${log#*.}"
    fi
    rm "$rotating"
}

# 0. A run that was interrupted may have left <name>.rotating files behind.
#    Archive them first; otherwise step 1 would write over them.
for log in "${LOGS[@]}"; do
    archive_rotated "$log"
done

# 1. Move the live files aside. nginx keeps writing to them under the new name
#    until it is told to reopen its logs. Empty files stay where they are.
MOVED=false
for log in "${LOGS[@]}"; do
    [ -s "$LOG_DIR/$log" ] || continue
    mv "$LOG_DIR/$log" "$LOG_DIR/$log.rotating"
    MOVED=true
done

if [ "$MOVED" = "true" ]; then
    # 2. nginx writes out what it still holds in memory and starts new files.
    #    If this fails the script stops here, on purpose: nginx may still be
    #    writing to the .rotating files, and they are picked up by the next run.
    docker compose exec -T nginx nginx -s reopen
    sleep 2

    # 3. Append to the monthly archives.
    for log in "${LOGS[@]}"; do
        archive_rotated "$log"
    done
fi

# 4. Retention (not on the nightly error-log run).
if [ "$ERROR_LOG_ONLY" = "false" ]; then
    # The oldest month to keep, as YYYY-MM. Months are counted as year*12+month
    # so the arithmetic works across year boundaries.
    year=$(date +%Y)
    month=$((10#$(date +%m)))
    oldest=$((year * 12 + month - 1 - RETENTION_MONTHS))
    OLDEST_KEPT=$(printf '%04d-%02d' $((oldest / 12)) $((oldest % 12 + 1)))

    for file in "$LOG_DIR"/access.[0-9][0-9][0-9][0-9]-[0-9][0-9].tsv.gz "$LOG_DIR"/error.[0-9][0-9][0-9][0-9]-[0-9][0-9].log.gz; do
        [ -e "$file" ] || continue
        name=$(basename "$file")
        file_month="${name#*.}"
        file_month="${file_month%%.*}"
        # YYYY-MM compares correctly as text.
        if [[ "$file_month" < "$OLDEST_KEPT" ]]; then
            echo "Deleting $name (older than $RETENTION_MONTHS months)"
            rm "$file"
        fi
    done
fi
