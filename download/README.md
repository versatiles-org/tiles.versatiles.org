# download-updater

Mirrors the `.versatiles` tile data from the CDN into the local `tiles/` volume and (re)generates
`versatiles.yaml` for the VersaTiles tile server.

It is a single bash script (`update-tiles.sh`) running in a minimal Alpine container with `aria2c`
(parallel downloads), `curl`, and the `versatiles` CLI (used to build zoom-limited subsets — see
[Partial datasets](#partial-datasets)). It is invoked once per run via `docker compose run --rm
download-updater [--mode=…]` — there is no long-running process.

## Source of truth

The `.versatiles` files are hosted on a public Cloudflare bucket, **`cdn.versatiles.cloud`** by
default (override with `CDN_BASE_URL`). Each dataset is a stable object key `<slug>.versatiles` with
a small `<slug>.versatiles.md5` checksum sidecar. The CDN exposes no listing, so the authoritative
set of datasets is the `DATASETS` array at the top of `update-tiles.sh` — add or remove slugs there
to change what is served. No credentials are involved.

A dataset is **current** when the local `<slug>.versatiles` exists and its stored
`<slug>.versatiles.md5` matches the CDN's; otherwise it is **stale** and gets (re)downloaded.

## Partial datasets

Some datasets are too large to mirror in full (satellite is ~2 TB). For these we keep only a
**zoom-limited local subset** (z0..N) and serve the higher zoom levels straight from the CDN, glued
together with a [VPL](https://docs.versatiles.org) pipeline. Partial datasets are declared in the
`PARTIAL_MAX_ZOOM` map at the top of `update-tiles.sh` (slug → max local zoom):

```bash
declare -A PARTIAL_MAX_ZOOM=(
	[satellite]=16
)
```

For a partial dataset the script:

- **Builds the subset** with `versatiles convert --max-zoom=N <CDN-URL> …` instead of `aria2c`. The
  convert reads the remote container over HTTP range requests, fetching only the tiles up to zoom `N`
  (satellite z0–16 is ~700 GB vs ~2 TB in full). The old subset is deleted first — the host disk
  cannot hold two copies, and in the two-phase flow the tile server is already serving from the CDN
  at that point, so the local file is not in use.
- **Writes a `<slug>.vpl`** into `versatiles_conf/` and points the dataset's `src` at
  `/config_dir/<slug>.vpl`. When the subset is **current** the pipeline stacks local over remote:

  ```vpl
  from_stacked [
     from_container filename="/data/tiles/satellite.versatiles" | filter level_max=16,
     from_container filename="https://cdn.versatiles.cloud/satellite.versatiles" | filter level_min=17
  ]
  ```

  `from_stacked` returns the tile from the first source that has it, and the two `filter`s pin the
  boundary: z0–16 come from local disk, z17+ from the CDN. When the subset is **stale/absent** (e.g.
  during `prepare`, or before the first build) the `.vpl` instead serves the whole dataset from the
  CDN, so there is no downtime while `finalize` rebuilds the subset.

> **Sidecar marker:** for a partial dataset the `<slug>.versatiles.md5` stores the **CDN full-file
> MD5** the subset was derived from — *not* the local subset's own hash. This is the version signal
> used to detect when the upstream file changed and the subset needs rebuilding. (Because the local
> file is a subset, its real hash would never match the CDN's, so it cannot be verified directly.)

## Modes

The script takes a single `--mode=` argument (default `finalize`):

| Mode       | Downloads? | Writes `versatiles.yaml`? | Purpose                                                                 |
| ---------- | ---------- | ------------------------- | ---------------------------------------------------------------------- |
| `check`    | no         | no                        | Read-only — report whether anything needs updating.                    |
| `prepare`  | no         | yes (transitional)        | Stale datasets point at the CDN, current ones at local disk (partial: CDN-only `.vpl`). |
| `finalize` | yes        | yes (final)               | Download/build stale datasets, delete unlisted ones, point all at local disk (partial: stacked `.vpl`). |

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
3. **Download** (`finalize` only) — clean up leftover temp files, delete `.versatiles` files no longer
   in `DATASETS`, then for each stale dataset either:
   - **full datasets:** download with `aria2c` (16 parallel connections, inline `--checksum=md5=…`
     verification, atomic temp file → rename), or
   - **partial datasets:** build the zoom-limited subset with `versatiles convert` (see
     [Partial datasets](#partial-datasets)).

   Write the local `.md5` sidecar (the CDN MD5) afterwards.
4. **Generate** — write `versatiles.yaml` atomically (temp file → rename), pointing each dataset at
   `/data/tiles/<slug>.versatiles` (local), `<CDN>/<slug>.versatiles` (stale, `prepare`), or
   `/config_dir/<slug>.vpl` (partial — the `.vpl` is also written atomically).

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
