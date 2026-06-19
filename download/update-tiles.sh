#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# update-tiles.sh — mirror the .versatiles tile data from the CDN and (re)generate
# versatiles.yaml for the VersaTiles tile server.
# =============================================================================
#
# The .versatiles files live behind a public Cloudflare bucket
# (cdn.versatiles.cloud). Each dataset is a stable object key <slug>.versatiles
# with a small <slug>.versatiles.md5 checksum sidecar. A dataset is "current"
# when the local file exists and its stored MD5 matches the CDN's. Stale or
# missing datasets are (re)downloaded with aria2c (parallel connections, inline
# MD5 verification). No credentials are involved — the CDN is public.
#
# Usage: update-tiles.sh [--mode=check|prepare|finalize]   (default: finalize)
#
#   check    Read-only: fetch MD5s, compare to local state, report whether
#            anything needs updating. Writes nothing.
#   prepare  Like check, but also writes a transitional versatiles.yaml that
#            points stale/missing datasets at the CDN (so the tile server keeps
#            serving them during the update) and current datasets at local disk.
#            Downloads nothing.
#   finalize Download stale/missing datasets (partial datasets: build their
#            zoom-limited subset), delete datasets no longer listed, and write a
#            versatiles.yaml pointing at local disk (partial datasets: a stacked
#            VPL serving local low zoom + CDN high zoom).
#
# Exit codes (consumed by bin/update.sh):
#   0  at least one dataset needs updating (or finalize completed)
#   1  pipeline error (abort)
#   2  nothing to update — only emitted in check/prepare
# =============================================================================

# Datasets to keep in sync. Each slug is the CDN object key (<slug>.versatiles,
# with a <slug>.versatiles.md5 sidecar) and the tile source `name` in the yaml.
# The CDN exposes no listing, so this is the authoritative set — add/remove here.
DATASETS=(
	osm
	satellite
	elevation
	landcover-vectors
	hillshade-vectors
	bathymetry-vectors
)

# Partial datasets: too large to mirror in full, so we keep only a zoom-limited
# local subset (z0..maxzoom) and serve the higher zoom levels straight from the
# CDN via a stacked VPL pipeline. Maps slug -> max local zoom. The satellite
# dataset is ~2 TB in full but only ~700 GB up to z16, which fits the host disk.
# See download_local_files (builds the subset with `versatiles convert`) and
# write_vpl (emits the pipeline).
declare -A PARTIAL_MAX_ZOOM=(
	[satellite]=15
)

# True if the given slug is a partial (zoom-limited local subset) dataset.
is_partial() { [ -n "${PARTIAL_MAX_ZOOM[$1]:-}" ]; }

VOLUME_FOLDER="${VOLUME_FOLDER:-/volumes}"
TILES_FOLDER="$VOLUME_FOLDER/tiles"
CONF_FOLDER="$VOLUME_FOLDER/versatiles_conf"

# Base URL of the CDN, with any trailing slashes stripped.
CDN_BASE_URL="${CDN_BASE_URL:-https://cdn.versatiles.cloud}"
while [ "${CDN_BASE_URL: -1}" = "/" ]; do CDN_BASE_URL="${CDN_BASE_URL%/}"; done

# Parse --mode= from the first argument; default to finalize.
MODE="finalize"
for arg in "$@"; do
	case "$arg" in
		--mode=check) MODE="check" ;;
		--mode=prepare) MODE="prepare" ;;
		--mode=finalize) MODE="finalize" ;;
		*) echo "Unknown argument: $arg" >&2; exit 1 ;;
	esac
done

# Per-dataset MD5 reported by the CDN, and whether the dataset is still remote
# (stale/missing) or already current on local disk. Indexed by array position.
declare -a MD5S
declare -a IS_REMOTE

# Extract the leading hash token from a checksum body ("<hash>  <filename>").
parse_hash() {
	local hash
	hash="${1%%[[:space:]]*}"
	if [ "${#hash}" -lt 32 ]; then
		echo "Invalid checksum body: \"${1:0:48}\"" >&2
		return 1
	fi
	printf '%s' "$hash"
}

# Reads the stored MD5 for a local file, or prints nothing if absent/invalid.
read_local_md5() {
	local path="$1.md5"
	[ -f "$path" ] || return 0
	local hash
	hash="$(<"$path")"
	hash="${hash%%[[:space:]]*}"
	[ "${#hash}" -ge 32 ] && printf '%s' "$hash"
}

# Fetch the current MD5 of every dataset from the CDN.
resolve_datasets() {
	echo "Resolving ${#DATASETS[@]} datasets from $CDN_BASE_URL..."
	local i body
	for i in "${!DATASETS[@]}"; do
		local url="$CDN_BASE_URL/${DATASETS[$i]}.versatiles.md5"
		if ! body="$(curl -fsS "$url")"; then
			echo "GET $url failed" >&2
			exit 1
		fi
		MD5S[i]="$(parse_hash "$body")"
		IS_REMOTE[i]=1
	done
}

# Marks each dataset current (IS_REMOTE=0) when the local file exists with a
# matching MD5, otherwise stale (IS_REMOTE=1). Downloads nothing. Sets the
# global NEEDS_UPDATE to 1 if any dataset needs updating.
NEEDS_UPDATE=0
check_local_files() {
	mkdir -p "$TILES_FOLDER"
	local i
	for i in "${!DATASETS[@]}"; do
		local file="${DATASETS[$i]}.versatiles"
		local path="$TILES_FOLDER/$file"
		if [ -f "$path" ] && [ "$(read_local_md5 "$path")" = "${MD5S[$i]}" ]; then
			IS_REMOTE[i]=0
		else
			IS_REMOTE[i]=1
			NEEDS_UPDATE=1
		fi
	done
}

# Removes leftover temp/control files from interrupted downloads (aria2c) and
# subset builds (versatiles convert writes <file>.tmp).
cleanup_temp_files() {
	local entry
	for entry in "$TILES_FOLDER"/*.download "$TILES_FOLDER"/*.aria2 "$TILES_FOLDER"/*.tmp.versatiles; do
		[ -e "$entry" ] || continue
		echo " - Cleaning up temp file: $(basename "$entry")"
		rm -f "$entry"
	done
}

# Deletes .versatiles files (and their .md5) that are not in DATASETS.
delete_unknown_files() {
	local wanted=""
	local slug
	for slug in "${DATASETS[@]}"; do wanted="$wanted $slug.versatiles "; done
	local entry
	for entry in "$TILES_FOLDER"/*.versatiles; do
		[ -e "$entry" ] || continue
		local file
		file="$(basename "$entry")"
		case "$wanted" in
			*" $file "*) ;;
			*)
				echo " - Deleting $file"
				rm -f "$entry" "$entry.md5"
				;;
		esac
	done
}

# Downloads stale/missing datasets from the CDN into TILES_FOLDER (partial
# datasets: builds their zoom-limited subset with `versatiles convert`) and
# removes any .versatiles files no longer part of DATASETS. Afterwards each
# dataset's local file is present (IS_REMOTE=0).
download_local_files() {
	mkdir -p "$TILES_FOLDER"
	echo "Syncing local files..."
	cleanup_temp_files
	delete_unknown_files

	local i
	for i in "${!DATASETS[@]}"; do
		local file="${DATASETS[$i]}.versatiles"
		local path="$TILES_FOLDER/$file"

		if [ -f "$path" ] && [ "$(read_local_md5 "$path")" = "${MD5S[$i]}" ]; then
			echo " - Keeping $file (already up to date)"
			IS_REMOTE[i]=0
			continue
		fi

		local url="$CDN_BASE_URL/$file"

		if is_partial "${DATASETS[$i]}"; then
			local maxzoom="${PARTIAL_MAX_ZOOM[${DATASETS[$i]}]}"
			# versatiles convert infers the output format from the file extension,
			# so the temp file must end in .versatiles (not .tmp).
			local building="${path%.versatiles}.tmp.versatiles"
			echo " - Building local subset of $file (z0-$maxzoom) from $url ..."
			# Free the old subset first: it is large (satellite ~700 GB) and the
			# host filesystem cannot hold two copies. In the two-phase update flow
			# the tile server is already serving this dataset from the CDN (the
			# transitional VPL written by prepare), so the local file is not in use
			# while finalize rebuilds it.
			rm -f "$path" "$path.md5" "$building"
			# versatiles convert reads the remote container over range requests,
			# fetching only the tiles up to maxzoom, and writes them locally. No
			# --tile-format / --compress so the subset stays byte-format-identical
			# to the remote (required for from_stacked).
			versatiles convert --max-zoom="$maxzoom" "$url" "$building"
			mv "$building" "$path"
		else
			echo " - Downloading $file from $url ..."
			aria2c \
				--dir="$TILES_FOLDER" \
				--out="$file.download" \
				--max-connection-per-server=16 \
				--split=16 \
				--min-split-size=10M \
				--max-tries=5 \
				--retry-wait=5 \
				--continue=true \
				--allow-overwrite=true \
				--auto-file-renaming=false \
				--checksum=md5="${MD5S[$i]}" \
				--console-log-level=warn \
				--summary-interval=0 \
				"$url"
			mv "$path.download" "$path"
		fi

		# Record the CDN full-file MD5 as the version marker. For partial datasets
		# this is intentionally NOT the local subset's own hash — it records which
		# CDN version the subset was derived from, so check_local_files can detect
		# when the upstream file changes and trigger a rebuild.
		printf '%s  %s\n' "${MD5S[$i]}" "$file" >"$path.md5"
		IS_REMOTE[i]=0
	done
}

# Writes the VPL pipeline file for a partial dataset (atomically: temp + rename).
#
# When the local subset is current (IS_REMOTE=0) it stacks the local low-zoom
# subset over the full remote file: z0..maxzoom served from local disk, the rest
# straight from the CDN. from_stacked uses first-match, so the explicit filters
# enforce the boundary (and stop the remote ever answering a low zoom).
#
# When the subset is stale/absent (IS_REMOTE=1, e.g. during prepare or before the
# first build) it serves the whole dataset from the CDN, so the tile server has
# no downtime while finalize rebuilds the subset.
write_vpl() {
	local i="$1"
	local slug="${DATASETS[$i]}"
	local file="$slug.versatiles"
	local maxzoom="${PARTIAL_MAX_ZOOM[$slug]}"
	local minremote=$((maxzoom + 1))
	local remote="$CDN_BASE_URL/$file"
	local out="$CONF_FOLDER/$slug.vpl"
	local tmp="$out.tmp"

	if [ "${IS_REMOTE[$i]}" -eq 1 ]; then
		cat >"$tmp" <<-VPL
			from_container filename="$remote"
		VPL
	else
		cat >"$tmp" <<-VPL
			from_stacked [
			   from_container filename="/data/tiles/$file" | filter level_max=$maxzoom,
			   from_container filename="$remote" | filter level_min=$minremote
			]
		VPL
	fi

	mv "$tmp" "$out"
}

# Removes VPL files for datasets that are no longer partial (or removed entirely).
delete_unknown_vpls() {
	local entry slug
	for entry in "$CONF_FOLDER"/*.vpl; do
		[ -e "$entry" ] || continue
		slug="$(basename "$entry" .vpl)"
		if ! is_partial "$slug"; then
			echo " - Removing stale $slug.vpl"
			rm -f "$entry"
		fi
	done
}

# Generates versatiles.yaml and writes it to disk atomically (temp + rename).
generate_versatiles_yaml() {
	echo "Generating versatiles.yaml..."
	mkdir -p "$CONF_FOLDER"
	local out="$CONF_FOLDER/versatiles.yaml"
	local tmp="$out.tmp"

	# Write the VPL pipeline files for partial datasets first; the yaml below
	# references each by its server-side path (/config_dir/<slug>.vpl). Then drop
	# any stale .vpl files for datasets that are no longer partial.
	local i
	for i in "${!DATASETS[@]}"; do
		is_partial "${DATASETS[$i]}" && write_vpl "$i"
	done
	delete_unknown_vpls

	{
		cat <<-'YAML'
			server:
			  ip: "0.0.0.0"
			  port: 8080

			static:
			  - src: /data/frontend/frontend.br.tar
			  - src: /data/frontend/styles.tar
			    prefix: /assets/styles

			tiles:
		YAML

		for i in "${!DATASETS[@]}"; do
			local file="${DATASETS[$i]}.versatiles"
			local src
			if is_partial "${DATASETS[$i]}"; then
				# Served via the stacked/transitional VPL written above.
				src="/config_dir/${DATASETS[$i]}.vpl"
			elif [ "${IS_REMOTE[$i]}" -eq 1 ]; then
				src="$CDN_BASE_URL/$file"
			else
				src="/data/tiles/$file"
			fi
			printf '  - name: %s\n    src: %s\n' "${DATASETS[$i]}" "$src"
		done
	} >"$tmp"

	mv "$tmp" "$out"
	echo " - versatiles.yaml successfully written"
}

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------
resolve_datasets

if [ "$MODE" = "finalize" ]; then
	download_local_files
else
	check_local_files
fi

# Read-only check mode: report status without writing any config.
if [ "$MODE" = "check" ]; then
	[ "$NEEDS_UPDATE" -eq 1 ] && exit 0 || exit 2
fi

generate_versatiles_yaml

# prepare signals "nothing to update" with exit 2 so update.sh can skip the
# intermediate restart and the finalize phase.
if [ "$MODE" = "prepare" ] && [ "$NEEDS_UPDATE" -eq 0 ]; then
	exit 2
fi

exit 0
