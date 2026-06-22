#!/usr/bin/env bash
set -euo pipefail

# Summarise the nginx referer logs: for every referer DOMAIN, the total
# transmitted data (rounded MB, all requests) and the number of tile requests.
#
# Input is the gzipped TSV written by nginx (log_format referer_stats):
#   referer <TAB> uri <TAB> body_bytes_sent <TAB> status
# Only successful (2xx) responses are logged. Rows include both tile requests
# (/tiles/…) and asset requests (/assets/…); the "tiles" count is restricted to
# the former, while "MB" sums all transmitted bytes.
#
# The referer is reduced to its host (scheme, port, path and query stripped, and
# lower-cased), so all requests from one site are grouped together. Requests with
# no referer are grouped under "(none)".
#
# The logs are rotated monthly (bin/log/rotate.sh): the live referer_stats.tsv.gz
# holds the current month, and referer_stats.<YYYY-MM>.tsv.gz holds past months.
# The timespan is therefore selected by file.
#
# Usage: referer_stats.sh [--month current|all|YYYY-MM] [FILE.tsv.gz ...]
#   --month current   (default) the current month only (live referer_stats.tsv.gz)
#   --month all        all months (live log + rotated files)
#   --month YYYY-MM    a specific rotated month, e.g. 2026-05
#   FILE...            explicit files to read (overrides --month)
#
# Output: an aligned table sorted by data descending: domain, MB, tiles.

cd "$(dirname "$0")/../.."

LOG_DIR="volumes/nginx-log"

usage() { sed -n '21,25p' "$0" | sed 's/^# \{0,1\}//'; }

# --- Arguments ---
MONTH="current"
files=()
while [ "$#" -gt 0 ]; do
	case "$1" in
		--month) MONTH="${2-}"; [ -n "$MONTH" ] || { echo "--month needs a value" >&2; exit 1; }; shift 2 ;;
		--month=*) MONTH="${1#--month=}"; shift ;;
		-h|--help) usage; exit 0 ;;
		-*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
		*) files+=("$1"); shift ;;
	esac
done

# --- Resolve input files from --month (unless explicit files were given) ---
if [ "${#files[@]}" -eq 0 ]; then
	case "$MONTH" in
		current) files=("$LOG_DIR/referer_stats.tsv.gz") ;;
		all)
			shopt -s nullglob
			files=("$LOG_DIR"/referer_stats*.tsv.gz)
			shopt -u nullglob
			;;
		[0-9][0-9][0-9][0-9]-[0-9][0-9]) files=("$LOG_DIR/referer_stats.$MONTH.tsv.gz") ;;
		*) echo "Invalid --month '$MONTH' (use: current, all, or YYYY-MM)." >&2; exit 1 ;;
	esac
fi

# Keep only files that actually exist.
present=()
for f in ${files[@]+"${files[@]}"}; do
	[ -e "$f" ] && present+=("$f")
done
if [ "${#present[@]}" -eq 0 ]; then
	echo "No matching referer_stats logs found (--month $MONTH, dir $LOG_DIR)." >&2
	exit 1
fi
files=("${present[@]}")

# Decompress each file best-effort: the live log is still being written by nginx,
# so its gzip stream may end mid-record — ignore that rather than abort.
decompress() {
	local f
	for f in "${files[@]}"; do
		gzip -cd -- "$f" 2>/dev/null || true
	done
}

# Align output with column(1) when available, otherwise emit raw TSV.
format() {
	if command -v column >/dev/null 2>&1; then
		column -t -s "$(printf '\t')"
	else
		cat
	fi
}

{
	printf 'domain\tMB\ttiles\n'
	decompress | awk -F'\t' '
		{
			dom = $1
			sub(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, "", dom)  # strip scheme://
			sub(/[\/:?#].*$/, "", dom)                     # strip port/path/query
			if (dom == "" || dom == "-") dom = "(none)"
			dom = tolower(dom)

			bytes[dom] += $3
			if ($2 ~ /^\/tiles\//) tiles[dom] += 1
			seen[dom] = 1
		}
		END {
			for (d in seen)
				printf "%s\t%d\t%d\n", d, int(bytes[d] / 1048576 + 0.5), tiles[d] + 0
		}
	' | sort -t"$(printf '\t')" -k2,2nr -k3,3nr
} | format
