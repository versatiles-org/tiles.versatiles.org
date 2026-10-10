#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

LOG_DIR="./volumes/nginx-log"
MONTH=$(date -d "yesterday" +%Y-%m 2>/dev/null || date -v-1d +%Y-%m)

# Rotate current logs
for log in access.tsv.gz referer_stats.tsv.gz error.log; do
    [ -f "$LOG_DIR/$log" ] || continue
    # Insert month before first extension: foo.log.gz → foo.2025-03.log.gz
    base="${log%%.*}"
    ext="${log#*.}"
    mv "$LOG_DIR/$log" "$LOG_DIR/${base}.${MONTH}.${ext}"
done

# Signal nginx to reopen log files
docker compose exec -T nginx nginx -s reopen

# Anonymise and compress the rotated error log.
#
# nginx writes its error log in a fixed format that cannot be configured: every
# line about a request carries the full client address and the request line
# with its query string, e.g.
#   … client: 203.0.113.57, server: …, request: "GET /x?token=… HTTP/2.0",
#   upstream: "http://…/x?token=…", referrer: "https://example.org/page?…"
# The access logs avoid all of that (see proxy.conf.template), so the same is
# done here once the file is no longer being written to:
#   - client address: last octet zeroed (IPv4) / cut to the first two groups (IPv6),
#     the same rule as $remote_addr_anon in nginx.conf
#   - request and upstream: query string removed
#   - referrer: reduced to scheme://host
# The live error.log is not anonymised — it holds at most one month.
ERROR_LOG="$LOG_DIR/error.${MONTH}.log"
if [ -f "$ERROR_LOG" ]; then
    sed -E \
        -e 's/(client: [0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/\1.0/g' \
        -e 's/(client: [0-9a-fA-F]*:[0-9a-fA-F]*):[0-9a-fA-F:.]*/\1::/g' \
        -e 's/(request: "[A-Z]+ [^ ?"]*)\?[^ "]*/\1/g' \
        -e 's/(upstream: "[^"?]*)\?[^"]*/\1/g' \
        -e 's/(referrer: "[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\/?#"]*)[^"]*/\1/g' \
        "$ERROR_LOG" | gzip >"$ERROR_LOG.gz"
    rm "$ERROR_LOG"
fi
