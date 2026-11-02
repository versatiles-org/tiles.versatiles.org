#!/usr/bin/env bash
set -euo pipefail

# Per-month traffic summary from the nginx referer logs. For each month it prints:
#   tiles      number of tile requests (uri starting with /tiles/)
#   tile_MB    transmitted data for those tile requests (rounded MB)
#   total_MB   transmitted data for ALL requests that month (rounded MB)
#
# Input is the gzipped TSV written by nginx (log_format referer_stats):
#   referer <TAB> uri <TAB> body_bytes_sent <TAB> status <TAB> hour <TAB> cdn <TAB> zone
# The month is taken from the hour column (YYYY-MM-DDTHH, UTC), so a late or missed
# rotation does not mix up months. Older lines have no hour column: for those it
# comes from the file name — referer_stats.<YYYY-MM>.tsv.gz is that month, and the
# live referer_stats.tsv.gz is reported as "current".
#
# Usage: monthly_traffic.sh [FILE.tsv.gz ...]
#   With no arguments, reads all referer_stats*.tsv.gz under volumes/nginx-log/.
#
# Output: an aligned table, one row per month (oldest first).

cd "$(dirname "$0")/../.."
source bin/log/helpers.sh

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

# Month label for lines without an hour column: "current" for the live log,
# "YYYY-MM" for a rotated one, otherwise the bare file name.
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
	progress_init "${files[@]}"
	for f in "${files[@]}"; do
		read_log "$f" | awk -F'\t' -v month="$(month_of "$f")" '
			{
				m = ($5 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-/) ? substr($5, 1, 7) : month
				seen[m] = 1
				total[m] += $3
				if ($2 ~ /^\/tiles\//) { tiles[m] += 1; tile[m] += $3 }
			}
			END {
				for (m in seen) printf "%s\t%d\t%.0f\t%.0f\n", m, tiles[m], tile[m], total[m]
			}
		'
	done | awk -F'\t' '
		# A month can span several files, e.g. lines that arrived just after a rotation.
		{ seen[$1] = 1; tiles[$1] += $2; tile[$1] += $3; total[$1] += $4 }
		END {
			for (m in seen)
				printf "%s\t%d\t%d\t%d\n", m, tiles[m], \
					int(tile[m] / 1048576 + 0.5), int(total[m] / 1048576 + 0.5)
		}
	' | sort -t"$(printf '\t')" -k1,1
	progress_done
} | format
