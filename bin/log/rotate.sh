#!/usr/bin/env bash
set -euo pipefail

# Rotates the nginx log files in volumes/nginx-log into archives, and deletes
# archives of the access and error logs once they are 28 days old.
#
# Usage:
#   rotate.sh   Run by cron every night just after midnight
#               (bin/log/setup_rotation.sh).
#
# The live files and their archives:
#   access.tsv.gz         → access.<YYYY-MM-DD>.tsv.gz       requests that went wrong
#   error.log             → error.<YYYY-MM-DD>.log.gz        nginx's own error log
#   referer_stats.tsv.gz  → referer_stats.<YYYY-MM>.tsv.gz   requests that were served
#
# The access and error logs are rotated every night, into one archive per day,
# so that each day can be deleted on its own after the retention period. The
# referer statistics hold no personal data and are kept without limit, in one
# archive per month (bin/log/monthly_traffic.sh builds its history from them);
# they are rotated in the first run of a month.
#
# A rotated log is APPENDED to its archive, never written over it. A gzip file
# may consist of several compressed parts in a row, so appending keeps the
# archive valid. That is what makes it safe to run this script more than once a
# night, e.g. by hand.
#
# The error log is also anonymised when it is rotated: nginx writes it in a
# fixed format that includes the full client address and request line (the
# access logs do not, see nginx/templates/proxy.conf.template). Rotating it
# every night keeps full addresses in the live file for a day at most.
#
# The day and month in the archive names are yesterday's: the script runs just
# after midnight, and what it rotates was written before.

cd "$(dirname "$0")/../.."

LOG_DIR="./volumes/nginx-log"

# How many days of access.* and error.* archives to keep. They exist for
# finding problems, misuse and attacks, and contain anonymised client addresses
# and user agents. The terms of use promise that they are deleted after 4 weeks.
RETENTION_DAYS=28

for arg in "$@"; do
    case "$arg" in
        # The nightly entry of the former cron schedule, until
        # bin/log/setup_rotation.sh replaces it: does the same as no argument.
        --error-log-only) ;;
        -h|--help) sed -n '4,9p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; echo "Usage: $0" >&2; exit 1 ;;
    esac
done

# GNU date on the server, BSD date when testing on macOS.
days_ago() {
    date -d "$1 days ago" +%Y-%m-%d 2>/dev/null || date -v-"$1"d +%Y-%m-%d
}

DAY=$(days_ago 1)
MONTH=${DAY%-*}

LOGS=(access.tsv.gz error.log)
# The first run of a month also closes the previous month's referer statistics.
if [ "$MONTH" != "$(date +%Y-%m)" ]; then
    LOGS+=(referer_stats.tsv.gz)
fi

# Appends a log that nginx no longer writes to (<name>.rotating) to its archive,
# then removes it.
archive_rotated() {
    local log="$1"
    local rotating="$LOG_DIR/$log.rotating"
    [ -f "$rotating" ] || return 0

    case "$log" in
        error.log)
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
                "$rotating" | gzip >>"$LOG_DIR/error.${DAY}.log.gz"
            ;;
        access.tsv.gz)
            # Already gzip-compressed by nginx: append as is.
            cat "$rotating" >>"$LOG_DIR/access.${DAY}.tsv.gz"
            ;;
        referer_stats.tsv.gz)
            cat "$rotating" >>"$LOG_DIR/referer_stats.${MONTH}.tsv.gz"
            ;;
    esac
    rm "$rotating"
}

# 0. A run that was interrupted may have left <name>.rotating files behind.
#    Archive them first; otherwise step 1 would write over them.
for log in access.tsv.gz error.log referer_stats.tsv.gz; do
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

    # 3. Append to the archives.
    for log in "${LOGS[@]}"; do
        archive_rotated "$log"
    done
fi

# 4. Retention. An archive is deleted when its oldest entry is RETENTION_DAYS
#    old: a daily archive with the day it was written, a monthly one (from before
#    the switch to daily archives) with the first day of its month. With the
#    run just after midnight, no entry is kept longer than RETENTION_DAYS days
#    and a few minutes.
OLDEST_KEPT=$(days_ago $((RETENTION_DAYS - 1)))

for file in "$LOG_DIR"/access.*.tsv.gz "$LOG_DIR"/error.*.log.gz; do
    [ -e "$file" ] || continue
    name=$(basename "$file")
    file_date="${name#*.}"
    file_date="${file_date%%.*}"
    case "$file_date" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]) file_date="$file_date-01" ;;
        *) continue ;;
    esac
    # YYYY-MM-DD compares correctly as text.
    if [[ "$file_date" < "$OLDEST_KEPT" ]]; then
        echo "Deleting $name (older than $RETENTION_DAYS days)"
        rm "$file"
    fi
done
