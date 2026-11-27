#!/usr/bin/env bash
set -euo pipefail

# Tests bin/nginx/check_version.sh against release lists shaped like GitHub's
# (file:// URLs, no network) at a fixed time: current, behind within the grace
# period, behind for longer, a line nginx.org no longer maintains, a list that
# can't be read, and the details it adds to a cron job's report.
#
# Needs curl. Usage: tests/nginx-version.sh
# Run by CI (.github/workflows/ci.yml). The same test as in photon-stack.

cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
cleanup() {
    rm -f "$TMP/releases.json" "$TMP/branched.json" "$TMP/empty.json" "$TMP/out" "$TMP/details"
    rmdir "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

# 2026-11-27T12:00:00Z
export NOW=1795780800

failed=0
fail() {
    echo "  FAIL: $*"
    failed=1
}
ok() { echo "  ok: $*"; }

# A release as GitHub lists it, with fields around the two that count and a
# release note that mentions a tag_name, escaped as GitHub escapes it.
release() {
    printf '{"url":"https://api.github.com/repos/nginx/nginx/releases/%s","tag_name":"release-%s","name":"nginx-%s","body":"Not \\"tag_name\\": \\"release-9.9.9\\"","draft":false,"prerelease":false,"created_at":"%s","published_at":"%s","assets":[{"name":"nginx-%s.tar.gz","created_at":"%s"}]}' \
        "$1" "$1" "$1" "$2" "$2" "$1" "$2"
}
{
    echo "["
    release 1.31.10 2026-11-26T15:39:30Z
    echo ","
    release 1.30.8 2026-11-23T15:37:37Z
    echo ","
    release 1.31.9 2026-11-18T15:54:06Z
    echo ","
    release 1.30.7 2026-11-18T15:56:40Z
    echo "]"
} >"$TMP/releases.json"
{
    echo "["
    release 1.33.0 2027-04-20T15:00:00Z
    echo ","
    release 1.32.0 2027-04-20T15:00:00Z
    echo ","
    release 1.31.12 2027-03-01T15:00:00Z
    echo "]"
} >"$TMP/branched.json"
echo "[]" >"$TMP/empty.json"

# Runs the check; sets $code and leaves its output in $TMP/out.
check() {
    code=0
    NGINX_RELEASES_URL="file://$1" bin/nginx/check_version.sh "$2" >"$TMP/out" 2>&1 || code=$?
}
expect() {
    local want_code=$1 pattern=$2 name=$3
    if [ "$code" = "$want_code" ] && grep -qE "$pattern" "$TMP/out"; then
        ok "$name"
    else
        fail "$name: exit code $code, output: $(cat "$TMP/out")"
    fi
}

echo "Checking bin/nginx/check_version.sh..."

check "$TMP/releases.json" 1.31.10
expect 0 "nginx 1.31.10 is the newest release of 1.31" "the newest release passes"

check "$TMP/releases.json" 1.30.8
expect 0 "nginx 1.30.8 is the newest release of 1.30" "the newest stable release passes"

check "$TMP/releases.json" 1.31.9
expect 0 "less than 2 days ago" "a release out for less than 2 days passes, with a note"

NOW=$((NOW + 3 * 24 * 60 * 60)) check "$TMP/releases.json" 1.31.9
expect 1 "Error: nginx 1.31.10 came out on 2026-11-26T15:39:30Z, but nginx still runs 1.31.9" \
    "a release out for more than 2 days fails"

check "$TMP/branched.json" 1.31.12
expect 1 "no longer maintains nginx 1.31 \(its lines: 1.32, 1.33\)" "a line no longer maintained fails"

check "$TMP/releases.json" 1.29.8
expect 1 "no longer maintains nginx 1.29" "an older line fails"

check "$TMP/no-such-file.json" 1.31.10
expect 0 "Warning: nginx's releases could not be read" "an unreadable list is only a warning"

check "$TMP/empty.json" 1.31.10
expect 0 "Warning: no releases found" "an empty list is only a warning"

check "$TMP/releases.json" ""
expect 1 "Error: can't tell which nginx version runs" "an unknown running version fails"

: >"$TMP/details"
code=0
REPORT_DETAILS="$TMP/details" NGINX_RELEASES_URL="file://$TMP/releases.json" \
    bin/nginx/check_version.sh 1.31.9 >/dev/null || code=$?
if [ "$code" = "0" ] && [ "$(cat "$TMP/details")" = "$(printf 'nginx=1.31.9\nnginx_newest=1.31.10')" ]; then
    ok "the running and the newest version go into the report's details"
else
    fail "details: exit code $code, $(cat "$TMP/details")"
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "bin/nginx/check_version.sh passed."
