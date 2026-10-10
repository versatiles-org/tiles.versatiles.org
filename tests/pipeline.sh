#!/usr/bin/env bash
set -euo pipefail

# Checks the update pipeline (download/): the image builds, download/sources.json
# is readable, and update-tiles.sh generates the tile server configuration that
# is expected for it. Downloads no tile data and needs no network beyond the
# image build.
#
# Usage: tests/pipeline.sh
# Run by CI (.github/workflows/ci.yml); run it locally after changing anything
# under download/.
#
# What is compared: the versatiles.yaml written in the two modes that work
# without the CDN —
#   transient  every dataset served from the CDN
#   local      every dataset served from local disk (placeholder files stand in
#              for the tile data), which also writes satellite.serve.vpl
# — against the files in tests/expected/. If you changed sources.json or the
# generator on purpose, look at the diff this script prints, and update the
# expected files to match.

cd "$(dirname "$0")/.."

IMAGE=tiles-updater-test

# Build with the versatiles image that compose.yaml pins, as compose itself does.
VERSATILES_IMAGE=$(DOMAIN_NAME=tiles.example.org RAM_DISK_GB=4 docker compose config --images | grep -E '^versatiles/versatiles:')
echo "Building the updater image with $VERSATILES_IMAGE"
docker build --quiet --build-arg "VERSATILES_IMAGE=$VERSATILES_IMAGE" -t "$IMAGE" download/ >/dev/null

# Runs a command in a fresh updater container whose /volumes is an empty RAM
# disk, and prints what the command prints.
in_updater() {
    docker run --rm --tmpfs /volumes:uid=1001,gid=1001 --entrypoint bash "$IMAGE" -c "$1"
}

# A command that puts an empty file in place of every dataset's tile data.
# Single quotes on purpose: $(…) and $n are for the shell inside the container.
# shellcheck disable=SC2016
PLACEHOLDERS='mkdir -p /volumes/tiles && for n in $(jq -r ".[].name" /app/sources.json); do touch "/volumes/tiles/$n.versatiles"; done'

FAILED=0

# compare <what> <expected file> <command that prints the actual content>
compare() {
    local what="$1" expected="$2" actual
    actual=$(in_updater "$3")
    if diff -u "$expected" <(echo "$actual") >/dev/null; then
        echo "  ok    $what"
    else
        echo "  FAIL  $what differs from $expected:"
        diff -u "$expected" <(echo "$actual") | sed 's/^/        /' || true
        FAILED=1
    fi
}

echo "Comparing the generated configuration with tests/expected/:"
compare "versatiles.yaml, transient mode" tests/expected/versatiles.transient.yaml \
    '/app/update-tiles.sh --mode=transient >/dev/null && cat /volumes/versatiles_conf/versatiles.yaml'
compare "versatiles.yaml, local mode" tests/expected/versatiles.local.yaml \
    "$PLACEHOLDERS"' && /app/update-tiles.sh --mode=local >/dev/null && cat /volumes/versatiles_conf/versatiles.yaml'
compare "satellite.serve.vpl, local mode" tests/expected/satellite.serve.vpl \
    "$PLACEHOLDERS"' && /app/update-tiles.sh --mode=local >/dev/null && cat /volumes/versatiles_conf/satellite.serve.vpl'

if [ "$FAILED" -ne 0 ]; then
    echo "Pipeline test FAILED"
    exit 1
fi
echo "Pipeline test OK"
