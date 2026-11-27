#!/usr/bin/env bash
set -euo pipefail

# Checks the nginx version that runs against nginx.org's releases, so that an
# nginx that no longer gets fixes doesn't go unnoticed. bin/nginx/update.sh
# runs it after each run: the daily rollout only picks up new images under the
# tag compose.yaml names (nginx:1.31-…), and once nginx.org stops releasing
# 1.31, that tag gets no new images and the rollout says "up to date" for ever.
#
# Usage: bin/nginx/check_version.sh <the running version, e.g. 1.31.10>
#
# Exits 1 when
#   - a newer release of the same line has been out for more than 2 days (the
#     official image usually follows within a day), or
#   - the line is no longer one that nginx.org maintains: the two newest lines,
#     the mainline (odd) and the stable one (even).
# Exits 0 otherwise, and also when the releases can't be read: that is only a
# warning, because it says nothing about nginx.
#
# Adds `nginx` (the running version) and `nginx_newest` (the newest of its
# line) to the report when it runs under bin/cron/run.sh. The report goes to
# the private dashboard only: it says whether nginx is up to date.
#
# The releases come from GitHub's list for nginx/nginx, where nginx publishes
# every release with its date. NGINX_RELEASES_URL and NOW (seconds since 1970)
# replace the source and the current time for tests/nginx-version.sh. The same
# script as bin/nginx/check_version.sh in photon-stack: keep both alike.

log() { echo "$(date -u +%FT%TZ) $*"; }

# A time in seconds since 1970 as ISO 8601, with GNU date and with BSD date.
iso() { date -u -d "@$1" +%FT%TZ 2>/dev/null || date -u -r "$1" +%FT%TZ; }

detail() {
    if [ -n "${REPORT_DETAILS:-}" ]; then echo "$1=$2" >>"$REPORT_DETAILS"; fi
}

GRACE_SECONDS=$((2 * 24 * 60 * 60))
URL=${NGINX_RELEASES_URL:-https://api.github.com/repos/nginx/nginx/releases?per_page=30}
NOW=${NOW:-$(date +%s)}

running=${1:-}
if ! [[ $running =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    log "Error: can't tell which nginx version runs ('$running')."
    exit 1
fi
line="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
patch=${BASH_REMATCH[3]}
detail nginx "$running"

if ! json=$(curl -fsS --max-time 20 --retry 2 "$URL" 2>&1); then
    log "Warning: nginx's releases could not be read, so the version isn't checked: $json"
    exit 0
fi

# One "<version> <date>" per release, read without jq: every release has its
# tag_name before its published_at. Quotes inside texts are escaped (\"), so a
# release note can't pass for one of these fields.
releases=$(grep -oE '"(tag_name|published_at)": *"[^"]*"' <<<"$json" |
    sed -E 's/^"[a-z_]+": *"(.*)"$/\1/' | paste -d ' ' - - |
    sed -nE 's/^release-([0-9]+\.[0-9]+\.[0-9]+) ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z)$/\1 \2/p' || true)
if [ -z "$releases" ]; then
    log "Warning: no releases found in nginx's release list, so the version isn't checked."
    exit 0
fi

# The two newest lines, e.g. "1.30 1.31".
maintained=$(awk '{ split($1, v, "."); print v[1] "." v[2] }' <<<"$releases" |
    sort -t . -k 1,1n -k 2,2n -u | tail -n 2 | tr '\n' ' ' | sed 's/ $//')
if ! [[ " $maintained " == *" $line "* ]]; then
    log "Error: nginx.org no longer maintains nginx $line (its lines: ${maintained// /, }). Move the nginx tag in compose.yaml to one of them."
    exit 1
fi

# The newest release of the running line: "<version> <date>".
newest=$(awk -v line="$line" '{ split($1, v, "."); if (v[1] "." v[2] == line) print v[3], $0 }' <<<"$releases" |
    sort -n | tail -n 1 | cut -d ' ' -f 2-)
newest_version=${newest% *}
published=${newest#* }
detail nginx_newest "$newest_version"

if [ "${newest_version##*.}" -le "$patch" ]; then
    log "nginx $running is the newest release of $line."
elif [[ $published > $(iso $((NOW - GRACE_SECONDS))) ]]; then
    log "nginx $newest_version came out on $published, less than 2 days ago; the official image usually follows within a day. nginx runs $running."
else
    log "Error: nginx $newest_version came out on $published, but nginx still runs $running. Check why the rollout didn't pick it up."
    exit 1
fi
