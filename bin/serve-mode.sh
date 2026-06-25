#!/usr/bin/env bash
set -euo pipefail

# Manually switch how the tile server sources its data, then reload it.
# This only rewrites versatiles.yaml and reloads the tile server (SIGHUP, no
# downtime) — it does not download, build, or delete any tile data, so it is
# fast and reversible.
#
# Usage: serve-mode.sh transient|local
#
#   transient  Serve every dataset straight from the CDN. Uses no local tile
#              data (any local files are left on disk, just not used). Handy to
#              free the tile server from local data — e.g. before moving/repairing
#              the tiles volume, or to come up immediately on a fresh box.
#   local      Serve datasets present on local disk from disk; any dataset whose
#              local file is missing falls back to the CDN.
#
# To populate or refresh local data (and switch back to local serving in the
# process), use ./bin/update.sh.

cd "$(dirname "$0")/.."
source bin/deploy/helpers.sh

MODE="${1:-}"
case "$MODE" in
	transient|local) ;;
	-h|--help) sed -n '8,17p' "$0"; exit 0 ;;
	*) echo "Usage: $0 transient|local" >&2; exit 1 ;;
esac

echo "Switching tile serving to '$MODE' mode..."
docker compose run --rm download-updater "--mode=$MODE"

# Re-read the new versatiles.yaml (SIGHUP reload unless compose state changed).
echo "Reloading tile server..."
up_with_config_fallback versatiles sighup
wait_for_healthy versatiles

# Drop cached tiles so clients don't get responses from the previous mode.
echo "Clearing tile cache..."
./bin/ramdisk/clear.sh

echo "Tile serving is now in '$MODE' mode."
