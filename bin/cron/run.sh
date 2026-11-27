#!/usr/bin/env bash
# No -e: the job's exit code is collected and passed on, not acted upon.
set -uo pipefail

# Runs a cron job and reports how it went to status.versatiles.org, where the
# private dashboard shows it (see status.versatiles.org, login/report.js).
#
# Usage: bin/cron/run.sh <job> <interval in seconds> <command> [arguments]
#   e.g. ./bin/cron/run.sh nginx-update 86400 ./bin/nginx/update.sh
#
# The job's output passes through unchanged, so the cron line's log file stays
# as it was; its last line becomes the report's message. The exit code is the
# job's own. The interval tells the dashboard when the next report is due, so
# it can show a job that stopped running. A job can add details (such as a
# version) by appending `key=value` lines to the file named by $REPORT_DETAILS,
# if that is set.
#
# REPORT_TOKEN in .env is this server's token from status.versatiles.org's
# .env (REPORT_TOKEN_TILES there). Without it, the job runs as before and
# nothing is reported. A report that fails is logged as a warning, and never
# fails the job. Some reports concern security (an nginx that isn't up to
# date), so they go to the private dashboard only, never to a public page.
#
# REPORT_TOKEN and REPORT_URL in the environment take precedence over .env;
# tests/cron-run.sh uses that. The same script as bin/cron/run.sh in
# photon-stack and status.versatiles.org: keep all three alike.

cd "$(dirname "$0")/../.." || exit 1

if [ $# -lt 3 ] || ! [[ $2 =~ ^[0-9]+$ ]]; then
    sed -n '8,9p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
fi
job=$1
interval=$2
shift 2

# A value from .env, without sourcing it, so the job gets the environment it
# had before. Surrounding quotes are removed.
env_value() {
    sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
if [ -z "${REPORT_TOKEN+set}" ]; then REPORT_TOKEN=$(env_value REPORT_TOKEN); fi
if [ -z "${REPORT_URL+set}" ]; then REPORT_URL=$(env_value REPORT_URL); fi
REPORT_URL=${REPORT_URL:-https://status.versatiles.org/report}

if [ -z "$REPORT_TOKEN" ]; then
    exec "$@"
fi

output=$(mktemp)
details=$(mktemp)
headers=$(mktemp)
response=$(mktemp)
trap 'rm -f "$output" "$details" "$headers" "$response"' EXIT

REPORT_DETAILS=$details "$@" 2>&1 | tee "$output"
code=${PIPESTATUS[0]}

# A JSON string. Control characters other than tabs are dropped.
json_string() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=$(printf '%s' "$s" | tr -d '\000-\037')
    printf '"%s"' "$s"
}

# The receiver accepts up to 500 characters of message, 20 details with keys of
# [a-z0-9_] and values of up to 200 characters. Anything beyond is cut here, so
# the report itself still arrives.
message=$(grep -v '^[[:space:]]*$' "$output" | tail -n 1 | cut -c 1-300)
detail_json=""
count=0
while { IFS= read -r line || [ -n "$line" ]; } && [ "$count" -lt 20 ]; do
    key=${line%%=*}
    [[ $line == *=* && $key =~ ^[a-z0-9_]{1,40}$ ]] || continue
    value=$(printf '%s' "${line#*=}" | cut -c 1-150)
    detail_json+="${detail_json:+,}$(json_string "$key"):$(json_string "$value")"
    count=$((count + 1))
done <"$details"

body=$(printf '{"job":%s,"exit_code":%d,"interval":%d,"message":%s,"details":{%s}}' \
    "$(json_string "$job")" "$code" "$interval" "$(json_string "$message")" "$detail_json")

# The token goes in a file, not on the command line, where `ps` would show it.
printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$REPORT_TOKEN" >"$headers"
status=$(curl -sS --max-time 10 --retry 3 --retry-connrefused -o "$response" -w '%{http_code}' \
    -X POST -H @"$headers" --data-binary "$body" "$REPORT_URL" 2>&1)
if [ "$status" = "204" ]; then
    echo "Reported $job to $REPORT_URL (exit code $code)."
else
    echo "Warning: reporting $job to $REPORT_URL failed: $status $(head -c 300 "$response")"
fi

exit "$code"
