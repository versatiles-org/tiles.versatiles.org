# download-updater

Mirrors the `.versatiles` tile data from the CDN into the local `tiles/` volume and (re)generates
`versatiles.yaml` for the VersaTiles tile server.

It is a single bash script (`update-tiles.sh`) running in a minimal Alpine container with `aria2c`
(parallel downloads) and `curl`. It is invoked once per run via `docker compose run --rm
download-updater [--mode=…]` — there is no long-running process.

## Source of truth

The `.versatiles` files are hosted on a public Cloudflare bucket, **`cdn.versatiles.cloud`** by
default (override with `CDN_BASE_URL`). Each dataset is a stable object key `<slug>.versatiles` with
a small `<slug>.versatiles.md5` checksum sidecar. The CDN exposes no listing, so the authoritative
set of datasets is the `DATASETS` array at the top of `update-tiles.sh` — add or remove slugs there
to change what is served. No credentials are involved.

A dataset is **current** when the local `<slug>.versatiles` exists and its stored
`<slug>.versatiles.md5` matches the CDN's; otherwise it is **stale** and gets (re)downloaded.

## Modes

The script takes a single `--mode=` argument (default `finalize`):

| Mode       | Downloads? | Writes `versatiles.yaml`? | Purpose                                                                 |
| ---------- | ---------- | ------------------------- | ---------------------------------------------------------------------- |
| `check`    | no         | no                        | Read-only — report whether anything needs updating.                    |
| `prepare`  | no         | yes (transitional)        | Stale datasets point at the CDN, current ones at local disk.           |
| `finalize` | yes        | yes (final)               | Download stale datasets, delete unlisted ones, point all at local disk.|

`prepare` lets the tile server keep serving stale tilesets directly from the CDN (no downtime) while
`finalize` downloads the new files in the background. See `../bin/update.sh` for the full two-phase
orchestration.

## Exit codes

| Code | Meaning                                                       |
| ---- | ------------------------------------------------------------ |
| `0`  | At least one dataset needs updating (or `finalize` completed). |
| `1`  | Pipeline error — abort.                                      |
| `2`  | Nothing to update (only emitted in `check` / `prepare`).    |

`bin/update.sh` uses exit `2` to skip the intermediate tile-server restart and the `finalize` phase.

## Pipeline (`update-tiles.sh`)

1. **Resolve** — fetch each dataset's `<slug>.versatiles.md5` from the CDN with `curl`.
2. **Compare** — diff the CDN MD5 against the local `<slug>.versatiles.md5` sidecar.
3. **Download** (`finalize` only) — clean up leftover aria2c temp/`.aria2` files, delete
   `.versatiles` files no longer in `DATASETS`, then download stale datasets with `aria2c`
   (16 parallel connections, inline `--checksum=md5=…` verification, atomic temp file → rename).
   Write the local `.md5` sidecar afterwards.
4. **Generate** — write `versatiles.yaml` atomically (temp file → rename), pointing each dataset at
   either `/data/tiles/<slug>.versatiles` (local) or `<CDN>/<slug>.versatiles` (stale, `prepare`).

## Configuration

| Variable        | Default                        | Purpose                                              |
| --------------- | ------------------------------ | ---------------------------------------------------- |
| `CDN_BASE_URL`  | `https://cdn.versatiles.cloud` | CDN hosting the `.versatiles` files and `.md5` sidecars. |
| `VOLUME_FOLDER` | `/volumes`                     | Root containing `tiles/` and `versatiles_conf/`.     |

## Volume mounts

| Host path                       | Container path                 | Purpose                                       |
| ------------------------------- | ------------------------------ | --------------------------------------------- |
| `./volumes/tiles`               | `/volumes/tiles`               | Tile files + their `.md5` sidecars (rw).      |
| `./volumes/versatiles_conf`     | `/volumes/versatiles_conf`     | Generated `versatiles.yaml` (rw).             |

The container runs as UID 1001, so both volumes must be owned by `1001:1001` (handled by
`bin/deploy/ensure.sh`).
