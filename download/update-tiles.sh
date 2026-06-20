#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# update-tiles.sh — produce the local .versatiles tile data and (re)generate
# versatiles.yaml for the VersaTiles tile server, driven by a source manifest.
# =============================================================================
#
# Each dataset is described declaratively in sources.json. A dataset is defined
# by up to four fields (all optional except `name`):
#
#   name               Served tile name and local file <name>.versatiles.
#   build              How to produce the local artifact:
#                        {kind:"mirror"}                 download <name> as-is
#                                                        (aria2c, inline MD5).
#                        {kind:"vpl", pipeline, compress} run the VPL pipeline
#                                                        through `versatiles
#                                                        convert` (subset, merge,
#                                                        meta_update, …).
#                      Default: {kind:"mirror"}.
#   serveCurrent       How to serve once the local artifact is fresh:
#                        {kind:"local"}  serve <name>.versatiles from disk.
#                        {kind:"vpl", pipeline}  serve a VPL (e.g. a local
#                                                low-zoom subset stacked over the
#                                                CDN). Default: {kind:"local"}.
#   serveTransitional  How to serve while the artifact is being (re)built:
#                        {kind:"remote"} serve <name>.versatiles from the CDN.
#                        {kind:"vpl", pipeline}  serve a VPL (pipeline omitted ⇒
#                                                reuse build.pipeline). Default:
#                                                {kind:"remote"}.
#   versionInputs      CDN keys whose MD5s compose the freshness marker.
#                      Default: [name]. Multiple inputs (e.g. a merge) rebuild
#                      when ANY input changes.
#
# Pipelines may use the placeholders {CDN} (the CDN base URL) and {LOCAL} (the
# tile server's local tiles dir, /data/tiles). The .versatiles files live behind
# a public Cloudflare bucket (download.versatiles.org); each input is a stable
# <slug>.versatiles key with a <slug>.versatiles.md5 sidecar. No credentials.
#
# Usage: update-tiles.sh [--mode=check|prepare|finalize|transient|local]
#                                                          (default: finalize)
#
# Update lifecycle:
#   check     Read-only: fetch MD5s, compare to local state, report whether
#             anything needs updating. Writes nothing.
#   prepare   Like check, but also writes a transitional versatiles.yaml that
#             serves stale/missing datasets via their serveTransitional (so the
#             tile server keeps serving during the update) and fresh ones via
#             serveCurrent. Builds/downloads nothing.
#   finalize  Build/download stale datasets, delete datasets no longer listed,
#             and write a versatiles.yaml serving everything via serveCurrent.
#
# Manual serving-mode switches (only rewrite versatiles.yaml — no resolve, no
# downloads, local files untouched; see bin/serve-mode.sh):
#   transient Serve every dataset from the CDN (serveTransitional).
#   local     Serve datasets present on local disk via serveCurrent; any missing
#             dataset falls back to the CDN.
#
# Exit codes (consumed by bin/update.sh):
#   0  at least one dataset needs updating (or finalize completed)
#   1  pipeline error (abort)
#   2  nothing to update — only emitted in check/prepare
# =============================================================================

VOLUME_FOLDER="${VOLUME_FOLDER:-/volumes}"
TILES_FOLDER="$VOLUME_FOLDER/tiles"
CONF_FOLDER="$VOLUME_FOLDER/versatiles_conf"

# Source manifest (defaults to the copy shipped next to this script).
MANIFEST="${MANIFEST:-$(dirname "$0")/sources.json}"

# Base URL of the CDN, with any trailing slashes stripped.
CDN_BASE_URL="${CDN_BASE_URL:-https://download.versatiles.org}"
while [ "${CDN_BASE_URL: -1}" = "/" ]; do CDN_BASE_URL="${CDN_BASE_URL%/}"; done

# Paths as seen by the *versatiles* container (not this updater). Used inside the
# generated versatiles.yaml and the {LOCAL} placeholder in pipelines.
SERVER_TILES_DIR="/data/tiles"
SERVER_CONF_DIR="/config_dir"

# Parse --mode= from the first argument; default to finalize.
MODE="finalize"
for arg in "$@"; do
	case "$arg" in
		--mode=check) MODE="check" ;;
		--mode=prepare) MODE="prepare" ;;
		--mode=finalize) MODE="finalize" ;;
		--mode=transient) MODE="transient" ;;
		--mode=local) MODE="local" ;;
		*) echo "Unknown argument: $arg" >&2; exit 1 ;;
	esac
done

# ---------------------------------------------------------------------------
# Manifest accessors (one jq call each; the manifest is tiny)
# ---------------------------------------------------------------------------
mapfile -t DATASETS < <(jq -r '.[].name' "$MANIFEST")

# ds_get <name> <jq-filter-relative-to-entry> <default>
ds_get() {
	local v
	v="$(jq -r --arg n "$1" ".[] | select(.name==\$n) | $2 // empty" "$MANIFEST")"
	printf '%s' "${v:-$3}"
}
ds_build_kind()       { ds_get "$1" '.build.kind' 'mirror'; }
ds_build_pipeline()   { ds_get "$1" '.build.pipeline' ''; }
ds_build_compress()   { ds_get "$1" '.build.compress' ''; }
ds_serve_kind()       { ds_get "$1" '.serveCurrent.kind' 'local'; }
ds_serve_pipeline()   { ds_get "$1" '.serveCurrent.pipeline' ''; }
ds_trans_kind()       { ds_get "$1" '.serveTransitional.kind' 'remote'; }
ds_trans_pipeline()   { ds_get "$1" '.serveTransitional.pipeline' ''; }
ds_version_inputs()   { jq -r --arg n "$1" '.[] | select(.name==$n) | (.versionInputs // [.name])[]' "$MANIFEST"; }

# Substitutes {CDN} and {LOCAL} placeholders in a pipeline string.
subst() {
	local s="$1"
	s="${s//\{CDN\}/$CDN_BASE_URL}"
	s="${s//\{LOCAL\}/$SERVER_TILES_DIR}"
	printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# MD5 helpers
# ---------------------------------------------------------------------------

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

# Fetch the current CDN MD5 of a slug (memoised).
declare -A CDN_MD5_CACHE
cdn_md5() {
	local slug="$1"
	if [ -z "${CDN_MD5_CACHE[$slug]:-}" ]; then
		local url="$CDN_BASE_URL/$slug.versatiles.md5" body
		if ! body="$(curl -fsS "$url")"; then
			echo "GET $url failed" >&2
			exit 1
		fi
		CDN_MD5_CACHE[$slug]="$(parse_hash "$body")"
	fi
	printf '%s' "${CDN_MD5_CACHE[$slug]}"
}

# The freshness marker for a dataset: the raw CDN MD5 for a single input
# (so plain mirror sidecars stay byte-compatible and aria2c can verify against
# it), or an MD5 of the joined input MD5s for a multi-input (e.g. merged)
# dataset, so it rebuilds whenever any input changes.
dataset_marker() {
	local -a inputs
	mapfile -t inputs < <(ds_version_inputs "$1")
	if [ "${#inputs[@]}" -le 1 ]; then
		cdn_md5 "${inputs[0]}"
	else
		local s
		{ for s in "${inputs[@]}"; do printf '%s\n' "$(cdn_md5 "$s")"; done; } | md5sum | cut -d' ' -f1
	fi
}

# ---------------------------------------------------------------------------
# Resolve / compare
# ---------------------------------------------------------------------------

# Warm the MD5 cache for every input (fails fast if the CDN is unreachable).
resolve_datasets() {
	echo "Resolving ${#DATASETS[@]} datasets from $CDN_BASE_URL..."
	local name s
	for name in "${DATASETS[@]}"; do
		while read -r s; do cdn_md5 "$s" >/dev/null; done < <(ds_version_inputs "$name")
	done
}

# Marks each dataset fresh (IS_REMOTE=0) when its local file exists with a
# matching marker, otherwise stale (IS_REMOTE=1). Sets NEEDS_UPDATE.
declare -A IS_REMOTE
NEEDS_UPDATE=0
check_local_files() {
	mkdir -p "$TILES_FOLDER"
	local name path
	for name in "${DATASETS[@]}"; do
		path="$TILES_FOLDER/$name.versatiles"
		if [ -f "$path" ] && [ "$(read_local_md5 "$path")" = "$(dataset_marker "$name")" ]; then
			IS_REMOTE[$name]=0
		else
			IS_REMOTE[$name]=1
			NEEDS_UPDATE=1
		fi
	done
}

# ---------------------------------------------------------------------------
# Build (finalize)
# ---------------------------------------------------------------------------

# Removes leftover temp/control files from interrupted downloads (aria2c) and
# VPL builds (versatiles convert writes <file>.tmp.versatiles).
cleanup_temp_files() {
	local entry
	for entry in "$TILES_FOLDER"/*.download "$TILES_FOLDER"/*.aria2 "$TILES_FOLDER"/*.tmp.versatiles; do
		[ -e "$entry" ] || continue
		echo " - Cleaning up temp file: $(basename "$entry")"
		rm -f "$entry"
	done
}

# Deletes .versatiles files (and their .md5) that are not in the manifest.
delete_unknown_files() {
	local wanted="" name
	for name in "${DATASETS[@]}"; do wanted="$wanted $name.versatiles "; done
	local entry file
	for entry in "$TILES_FOLDER"/*.versatiles; do
		[ -e "$entry" ] || continue
		file="$(basename "$entry")"
		case "$wanted" in
			*" $file "*) ;;
			*) echo " - Deleting $file"; rm -f "$entry" "$entry.md5" ;;
		esac
	done
}

# Builds each stale dataset's local file (mirror download or VPL convert) and
# removes files no longer in the manifest. Afterwards every dataset's local
# file is present (IS_REMOTE=0).
download_local_files() {
	mkdir -p "$TILES_FOLDER"
	echo "Syncing local files..."
	cleanup_temp_files
	delete_unknown_files

	local name file path marker kind
	for name in "${DATASETS[@]}"; do
		file="$name.versatiles"
		path="$TILES_FOLDER/$file"
		marker="$(dataset_marker "$name")"

		if [ -f "$path" ] && [ "$(read_local_md5 "$path")" = "$marker" ]; then
			echo " - Keeping $file (already up to date)"
			IS_REMOTE[$name]=0
			continue
		fi

		kind="$(ds_build_kind "$name")"
		if [ "$kind" = "mirror" ]; then
			local url="$CDN_BASE_URL/$file"
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
				--checksum=md5="$marker" \
				--console-log-level=warn \
				--summary-interval=0 \
				"$url"
			mv "$path.download" "$path"
		elif [ "$kind" = "vpl" ]; then
			# versatiles convert infers the output format from the file extension,
			# so the temp file must end in .versatiles (not .tmp).
			local building="${path%.versatiles}.tmp.versatiles"
			local pipeline compress
			pipeline="$(subst "$(ds_build_pipeline "$name")")"
			compress="$(ds_build_compress "$name")"
			echo " - Building $file via VPL ..."
			# Free the old artifact first: derived files are large and the host
			# disk cannot hold two copies. In the two-phase update flow the tile
			# server is already serving this dataset via serveTransitional, so the
			# local file is not in use while finalize rebuilds it.
			rm -f "$path" "$path.md5" "$building"
			if [ -n "$compress" ]; then
				versatiles convert -c "$compress" "[,vpl]($pipeline)" "$building"
			else
				versatiles convert "[,vpl]($pipeline)" "$building"
			fi
			mv "$building" "$path"
		else
			echo "Unknown build kind '$kind' for $name" >&2
			exit 1
		fi

		# Record the freshness marker. For derived datasets this is intentionally
		# NOT the local file's own hash — it records which CDN input version(s) the
		# artifact was built from, so check_local_files can detect upstream changes.
		printf '%s  %s\n' "$marker" "$file" >"$path.md5"
		IS_REMOTE[$name]=0
	done
}

# ---------------------------------------------------------------------------
# Generate versatiles.yaml (+ any VPL files)
# ---------------------------------------------------------------------------

# Writes a VPL file atomically: write_vpl_file <basename-without-ext> <content>
write_vpl_file() {
	local out="$CONF_FOLDER/$1.vpl" tmp
	tmp="$out.tmp"
	printf '%s\n' "$2" >"$tmp"
	mv "$tmp" "$out"
}

# Removes .vpl files not in the given wanted list (passed by name).
prune_vpls() {
	local -n _wanted="$1"
	local entry base w keep
	for entry in "$CONF_FOLDER"/*.vpl; do
		[ -e "$entry" ] || continue
		base="$(basename "$entry" .vpl)"
		keep=0
		for w in ${_wanted[@]+"${_wanted[@]}"}; do
			if [ "$w" = "$base" ]; then keep=1; break; fi
		done
		if [ "$keep" -eq 0 ]; then
			echo " - Removing stale $base.vpl"
			rm -f "$entry"
		fi
	done
}

generate_versatiles_yaml() {
	echo "Generating versatiles.yaml..."
	mkdir -p "$CONF_FOLDER"
	local out="$CONF_FOLDER/versatiles.yaml" tmp
	tmp="$out.tmp"

	# Resolve each dataset's `src`, writing any serve/transitional .vpl files as a
	# side effect. Done in the parent shell (NOT a command substitution) so the
	# wanted-list appends survive; the freshly written .vpl files would otherwise
	# be pruned below.
	local -a wanted_vpls=()
	local -A src=()
	local name p
	for name in "${DATASETS[@]}"; do
		if [ "${IS_REMOTE[$name]}" -eq 0 ]; then
			# Fresh — serve via serveCurrent.
			if [ "$(ds_serve_kind "$name")" = "vpl" ]; then
				write_vpl_file "$name.serve" "$(subst "$(ds_serve_pipeline "$name")")"
				wanted_vpls+=("$name.serve")
				src[$name]="$SERVER_CONF_DIR/$name.serve.vpl"
			else
				src[$name]="$SERVER_TILES_DIR/$name.versatiles"
			fi
		else
			# Stale/missing — serve via serveTransitional.
			if [ "$(ds_trans_kind "$name")" = "vpl" ]; then
				p="$(ds_trans_pipeline "$name")"
				[ -z "$p" ] && p="$(ds_build_pipeline "$name")"  # default: reuse build pipeline
				write_vpl_file "$name.transitional" "$(subst "$p")"
				wanted_vpls+=("$name.transitional")
				src[$name]="$SERVER_CONF_DIR/$name.transitional.vpl"
			else
				src[$name]="$CDN_BASE_URL/$name.versatiles"
			fi
		fi
	done
	prune_vpls wanted_vpls

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
		for name in "${DATASETS[@]}"; do
			printf '  - name: %s\n    src: %s\n' "$name" "${src[$name]}"
		done
	} >"$tmp"

	mv "$tmp" "$out"
	echo " - versatiles.yaml successfully written"
}

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

# Manual serving-mode switches: just (re)write versatiles.yaml — no resolve, no
# downloads, no changes to local files. See bin/serve-mode.sh.
if [ "$MODE" = "transient" ]; then
	# Serve every dataset from the CDN (serveTransitional), ignoring local files.
	for name in "${DATASETS[@]}"; do IS_REMOTE[$name]=1; done
	generate_versatiles_yaml
	exit 0
fi
if [ "$MODE" = "local" ]; then
	# Serve each dataset that is present on local disk from disk (serveCurrent);
	# any missing dataset falls back to the CDN. Presence-based, not freshness —
	# this is a serving switch, not an update.
	mkdir -p "$TILES_FOLDER"
	for name in "${DATASETS[@]}"; do
		if [ -f "$TILES_FOLDER/$name.versatiles" ]; then IS_REMOTE[$name]=0; else IS_REMOTE[$name]=1; fi
	done
	generate_versatiles_yaml
	exit 0
fi

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
