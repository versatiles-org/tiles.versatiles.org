#!/usr/bin/env bash
set -euo pipefail

# Tests bin/cron/run.sh against a stand-in for status.versatiles.org's
# POST /report: a small Python server that records each request and answers
# 204, or 400 for the job `bad-job`. Checks that the job's exit code and output
# pass through, that the report carries the token, the exit code, the last line
# and the details as valid JSON, and that a failed report doesn't fail the job.
#
# Needs python3 and curl. Usage: tests/cron-run.sh
# Run by CI (.github/workflows/ci.yml).

cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
RECEIVER_PID=""
cleanup() {
    [ -z "$RECEIVER_PID" ] || kill "$RECEIVER_PID" 2>/dev/null || true
    rm -f "$TMP/receiver.py" "$TMP/port" "$TMP/request" "$TMP/out" "$TMP/job.sh"
    rmdir "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

failed=0
fail() {
    echo "  FAIL: $*"
    failed=1
}
ok() { echo "  ok: $*"; }

cat >"$TMP/receiver.py" <<'EOF'
import http.server, json, sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        with open(sys.argv[2], "w") as f:
            json.dump({"auth": self.headers.get("Authorization"), "body": body}, f)
        bad = json.loads(body).get("job") == "bad-job"
        self.send_response(400 if bad else 204)
        self.end_headers()
        if bad:
            self.wfile.write(b"job: rejected for the test\n")

    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
EOF
python3 -I "$TMP/receiver.py" "$TMP/port" "$TMP/request" &
RECEIVER_PID=$!
for _ in $(seq 1 50); do
    [ -s "$TMP/port" ] && break
    sleep 0.1
done
REPORT_URL="http://127.0.0.1:$(cat "$TMP/port")/report"
export REPORT_URL

# A job that prints a few lines, adds details and exits with the code given.
cat >"$TMP/job.sh" <<'EOF'
#!/usr/bin/env bash
echo "first line"
printf 'with "quotes", a \\ backslash\tand a tab\n'
echo ""
if [ -n "${REPORT_DETAILS:-}" ]; then
    echo "nginx=1.31.10" >>"$REPORT_DETAILS"
    echo "Not A Key=ignored" >>"$REPORT_DETAILS"
fi
exit "${1:-0}"
EOF
chmod +x "$TMP/job.sh"

# The value of a field in the recorded request, read with Python's json.
field() {
    python3 -I -c 'import json, sys
r = json.load(open(sys.argv[1]))
v = r["auth"] if sys.argv[2] == "auth" else json.loads(r["body"])
for k in sys.argv[2:] if sys.argv[2] != "auth" else []:
    v = v[k]
print(v)' "$TMP/request" "$@"
}

echo "Checking bin/cron/run.sh..."

# Without a token: the job runs as before, nothing is reported.
code=0
REPORT_TOKEN="" bin/cron/run.sh test-job 86400 "$TMP/job.sh" 3 >"$TMP/out" || code=$?
if [ "$code" = "3" ] && grep -q "first line" "$TMP/out" && [ ! -e "$TMP/request" ]; then
    ok "without a token, the job runs with its exit code and nothing is reported."
else
    fail "without a token: exit code $code, output or report not as expected."
fi

# With a token: the report carries everything, the exit code is the job's.
code=0
REPORT_TOKEN=secret-token bin/cron/run.sh test-job 86400 "$TMP/job.sh" 3 >"$TMP/out" || code=$?
[ "$code" = "3" ] || fail "the exit code is $code, expected the job's 3."
grep -q "first line" "$TMP/out" || fail "the job's output didn't pass through."
grep -q "^Reported test-job" "$TMP/out" || fail "the report wasn't confirmed: $(tail -n 1 "$TMP/out")"
[ "$(field auth)" = "Bearer secret-token" ] || fail "the token isn't sent as a bearer token."
[ "$(field job)" = "test-job" ] || fail "job is '$(field job)'."
[ "$(field exit_code)" = "3" ] || fail "exit_code is '$(field exit_code)'."
[ "$(field interval)" = "86400" ] || fail "interval is '$(field interval)'."
[ "$(field message)" = "$(printf 'with "quotes", a \\ backslash\tand a tab')" ] ||
    fail "message is '$(field message)', expected the last line that isn't empty."
[ "$(field details nginx)" = "1.31.10" ] || fail "details.nginx is missing."
[ "$(field details)" = "{'nginx': '1.31.10'}" ] || fail "details has more than the valid key: $(field details)."
[ "$failed" -ne 0 ] || ok "a report carries the token, exit code, interval, last line and details."

# A rejected report: a warning, and the job's exit code all the same.
code=0
REPORT_TOKEN=secret-token bin/cron/run.sh bad-job 86400 "$TMP/job.sh" 0 >"$TMP/out" || code=$?
if [ "$code" = "0" ] && grep -q "^Warning: reporting bad-job .*400 job: rejected" "$TMP/out"; then
    ok "a rejected report leads to a warning, not to a failed job."
else
    fail "a rejected report: exit code $code, last line '$(tail -n 1 "$TMP/out")'."
fi

# Wrong usage.
code=0
bin/cron/run.sh test-job daily "$TMP/job.sh" 2>/dev/null || code=$?
if [ "$code" = "2" ]; then
    ok "an interval that isn't a number is refused."
else
    fail "an interval that isn't a number: exit code $code, expected 2."
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "bin/cron/run.sh passed."
