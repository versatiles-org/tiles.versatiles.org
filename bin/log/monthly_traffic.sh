#!/usr/bin/env bash
set -euo pipefail

# Per-month traffic summary from the nginx referer logs. For each month it prints:
#   tiles      number of tile requests (uri starting with /tiles/)
#   tile_MB    transmitted data for those tile requests (rounded MB)
#   total_MB   transmitted data for ALL requests that month (rounded MB)
#
# Input is the gzipped TSV written by nginx (log_format referer_stats):
#   referer <TAB> uri <TAB> body_bytes_sent <TAB> status
# The logs rotate monthly (bin/log/rotate.sh): the live referer_stats.tsv.gz is
# the current month, and referer_stats.<YYYY-MM>.tsv.gz are past months — so the
# month is taken from the file name and each file is summed separately.
#
# Usage: monthly_traffic.sh [FILE.tsv.gz ...]
#   With no arguments, reads all referer_stats*.tsv.gz under volumes/nginx-log/.
#
# Output: an aligned table, one row per month (oldest first, current month last).

cd "$(dirname "$0")/../.."

LOG_DIR="volumes/nginx-log"

# Input files: explicit arguments, or every referer_stats log in the log dir.
if [ "$#" -gt 0 ]; then
	files=("$@")
else
	shopt -s nullglob
	files=("$LOG_DIR"/referer_stats*.tsv.gz)
	shopt -u nullglob
fi

present=()
for f in ${files[@]+"${files[@]}"}; do
	[ -e "$f" ] && present+=("$f")
done
if [ "${#present[@]}" -eq 0 ]; then
	echo "No referer_stats logs found in $LOG_DIR." >&2
	exit 1
fi
files=("${present[@]}")

# Month label for a log file: "current" for the live log, "YYYY-MM" for a rotated
# one, otherwise the bare file name.
month_of() {
	local b
	b="$(basename "$1")"
	case "$b" in
		referer_stats.tsv.gz) printf 'current' ;;
		referer_stats.*.tsv.gz) b="${b#referer_stats.}"; printf '%s' "${b%.tsv.gz}" ;;
		*) printf '%s' "$b" ;;
	esac
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
	printf 'month\ttiles\ttile_MB\ttotal_MB\n'
	for f in "${files[@]}"; do
		# Best-effort decompress: the live log is still being written, so its gzip
		# stream may end mid-record — ignore that rather than abort.
		{ gzip -cd -- "$f" 2>/dev/null || true; } | awk -F'\t' -v month="$(month_of "$f")" '
			{ total += $3; if ($2 ~ /^\/tiles\//) { tiles += 1; tile += $3 } }
			END {
				printf "%s\t%d\t%d\t%d\n", month, tiles + 0, \
					int(tile / 1048576 + 0.5), int(total / 1048576 + 0.5)
			}
		'
	done | sort -t"$(printf '\t')" -k1,1
} | format
