#!/usr/bin/env bash
# Shared helper functions for the log scripts. Source this file, don't execute it.

# Reading the gzipped logs, with a progress line on stderr:
#   [2/5] referer_stats.2026-04.tsv.gz   42.0%  0:31 elapsed  ~0:43 left (~1:14 total)
#
# Progress is measured on the compressed input: the bytes read so far against
# the total size of all files, which is known upfront. That gives a percentage
# and an estimate of the remaining and total duration. The line is only drawn
# when stderr is a terminal (and perl is available), so redirected output stays
# clean.
#
# Usage:
#   progress_init "${files[@]}"   # once, with every file that will be read
#   read_log FILE | ...           # per file, in the same order
#   progress_done                 # clear the progress line afterwards

PROGRESS_FILES=()
PROGRESS_SIZES=()
PROGRESS_TOTAL=0
PROGRESS_START=0

progress_init() {
	local f size
	PROGRESS_FILES=("$@")
	PROGRESS_SIZES=()
	PROGRESS_TOTAL=0
	for f in "$@"; do
		size=$(wc -c <"$f")
		PROGRESS_SIZES+=("$((size))")
		PROGRESS_TOTAL=$((PROGRESS_TOTAL + size))
	done
	PROGRESS_START=$(date +%s)
}

progress_enabled() {
	[ -t 2 ] && command -v perl >/dev/null 2>&1
}

# Clear the progress line once all files are read.
progress_done() {
	if progress_enabled; then printf '\r\033[K' >&2; fi
}

# Decompress FILE to stdout, best-effort: the live log is still being written by
# nginx, so its gzip stream may end mid-record — ignore that rather than abort.
read_log() {
	local f="$1" i offset=0
	if ! progress_enabled; then
		gzip -cd -- "$f" 2>/dev/null || true
		return
	fi
	# Bytes of all files before FILE count as already read.
	for i in "${!PROGRESS_FILES[@]}"; do
		[ "${PROGRESS_FILES[$i]}" = "$f" ] && break
		offset=$((offset + PROGRESS_SIZES[i]))
	done
	progress_cat "$f" "[$((i + 1))/${#PROGRESS_FILES[@]}] $(basename "$f")" "$offset" |
		gzip -cd 2>/dev/null || true
}

# Copy FILE to stdout unchanged, redrawing the progress line (at most once per
# second) with LABEL. OFFSET is the number of bytes read before this file.
progress_cat() {
	perl -e '
		use strict; use warnings;
		my ($file, $label, $done, $total, $start) = @ARGV;
		open(my $in, "<:raw", $file) or die "$file: $!\n";
		binmode STDOUT;

		sub duration {
			my $s = int(shift);
			return $s >= 3600
				? sprintf("%d:%02d:%02d", $s / 3600, $s / 60 % 60, $s % 60)
				: sprintf("%d:%02d", $s / 60, $s % 60);
		}

		my ($buf, $shown) = ("", -1);
		while (my $n = sysread($in, $buf, 1 << 20)) {
			print $buf;
			$done += $n;
			my $now = time;
			next if $now == $shown;
			$shown = $now;

			# The live log may have grown since its size was taken — cap at 100%.
			my $frac = $total > 0 && $done < $total ? $done / $total : 1;
			my $elapsed = $now - $start;
			my $eta = $elapsed > 0
				? sprintf("~%s left (~%s total)", duration($elapsed / $frac - $elapsed), duration($elapsed / $frac))
				: "";
			printf STDERR "\r\033[K%s  %5.1f%%  %s elapsed  %s", $label, 100 * $frac, duration($elapsed), $eta;
		}
	' "$1" "$2" "$3" "$PROGRESS_TOTAL" "$PROGRESS_START"
}
