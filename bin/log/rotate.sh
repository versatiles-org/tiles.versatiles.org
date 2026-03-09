#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

LOG_DIR="./volumes/nginx-log"
MONTH=$(date -d "yesterday" +%Y-%m 2>/dev/null || date -v-1d +%Y-%m)

# Rotate current logs
for log in access.log.gz referer_stats.tsv.gz error.log; do
    [ -f "$LOG_DIR/$log" ] || continue
    # Insert month before first extension: foo.log.gz → foo.2025-03.log.gz
    base="${log%%.*}"
    ext="${log#*.}"
    mv "$LOG_DIR/$log" "$LOG_DIR/${base}.${MONTH}.${ext}"
done

# Signal nginx to reopen log files
docker compose exec -T nginx nginx -s reopen

# Compress rotated error log
[ -f "$LOG_DIR/error.${MONTH}.log" ] && gzip "$LOG_DIR/error.${MONTH}.log"
