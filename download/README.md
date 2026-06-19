# download-updater

Produces the local `.versatiles` tile data and (re)generates `versatiles.yaml` for the VersaTiles
tile server, driven by a declarative source manifest ([`sources.json`](sources.json)).

It is a single bash script (`update-tiles.sh`) running in a minimal Alpine container with `aria2c`
(parallel downloads), `curl`, `jq` (reads the manifest), and the `versatiles` CLI (builds derived
datasets via [VPL](https://docs.versatiles.org)). It is invoked once per run via `docker compose run
--rm download-updater [--mode=…]` — there is no long-running process.

## Source of truth

The inputs are hosted on a public Cloudflare bucket, **`cdn.versatiles.cloud`** by default (override
with `CDN_BASE_URL`). Each input is a stable object key `<slug>.versatiles` with a small
`<slug>.versatiles.md5` checksum sidecar. No credentials are involved.

The CDN exposes no listing, so the authoritative set of served datasets — and how each is produced —
is **`sources.json`**. A dataset is **current** when its local `<slug>.versatiles` exists and its
stored `<slug>.versatiles.md5` marker matches the expected one; otherwise it is **stale** and gets
(re)built.

## Source manifest (`sources.json`)

A JSON array of dataset definitions. Every field except `name` is optional and has a sensible default,
so a plain mirrored dataset is a one-liner:

```jsonc
[
  { "name": "elevation" },                       // mirror → serve local file → CDN while updating

  { "name": "satellite",                         // keep only z0–15 locally, stack the CDN on top
    "build":        { "kind": "vpl",
                      "pipeline": "from_container filename=\"{CDN}/satellite.versatiles\" | filter level_max=15" },
    "serveCurrent": { "kind": "vpl",
                      "pipeline": "from_stacked [ from_container filename=\"{LOCAL}/satellite.versatiles\" | filter level_max=15, from_container filename=\"{CDN}/satellite.versatiles\" | filter level_min=16 ]" } },

  { "name": "osm",                               // merge osm + landcover into one attributed file
    "versionInputs": ["osm", "landcover-vectors"],
    "build":             { "kind": "vpl", "compress": "brotli",
                           "pipeline": "from_merged_vector [ from_container filename=\"{CDN}/osm.versatiles\", from_container filename=\"{CDN}/landcover-vectors.versatiles\" ] | meta_update attribution='…'" },
    "serveTransitional": { "kind": "vpl" } }     // omit pipeline ⇒ reuse build.pipeline (live merge from CDN)
]
```

### Fields

| Field               | Default            | Meaning                                                                                  |
| ------------------- | ------------------ | ---------------------------------------------------------------------------------------- |
| `name`              | —                  | Served tile name and local file `<name>.versatiles`.                                      |
| `build`             | `{kind:"mirror"}`  | `mirror` = download `<name>` as-is (aria2c, inline MD5). `vpl` = run `pipeline` through `versatiles convert` (`compress` optional, e.g. `brotli`). |
| `serveCurrent`      | `{kind:"local"}`   | How to serve once fresh. `local` = the built file. `vpl` = serve `pipeline` (e.g. a local low-zoom subset stacked over the CDN). |
| `serveTransitional` | `{kind:"remote"}`  | How to serve while (re)building. `remote` = the CDN file. `vpl` = serve `pipeline` (omit ⇒ reuse `build.pipeline`). |
| `versionInputs`     | `[name]`           | CDN keys whose MD5s form the freshness marker; multiple inputs rebuild when **any** changes. |

Pipelines may use the placeholders **`{CDN}`** (the CDN base URL) and **`{LOCAL}`** (the tile
server's local tiles dir, `/data/tiles`). `vpl` serve/transitional pipelines are written to
`versatiles_conf/<name>.serve.vpl` / `<name>.transitional.vpl` and referenced from the yaml; stale
`.vpl` files are pruned each run.

To **add or finetune a source** (zoom limit, merge, attribution via `meta_update`, …), edit
`sources.json` — no changes to `update-tiles.sh`.

JSON has no comments, so use a **`"//"` key** for notes (a string or array of strings). The engine
only reads the fields above, so any extra key is ignored — see the `satellite` and `osm` entries.

> **Freshness marker:** the `<slug>.versatiles.md5` sidecar stores the **marker**, not necessarily the
> local file's own hash. For a single-input dataset it is the raw CDN MD5 (so mirror downloads can be
> verified by aria2c). For a derived dataset it records which CDN input version(s) the artifact was
> built from — a derived file's real hash would never match any single CDN file, so it can't be
> verified directly; the marker is the rebuild trigger instead.

## Modes

The script takes a single `--mode=` argument (default `finalize`):

| Mode       | Builds? | Writes `versatiles.yaml`? | Purpose                                                            |
| ---------- | ------- | ------------------------- | ----------------------------------------------------------------- |
| `check`    | no      | no                        | Read-only — report whether anything needs updating.               |
| `prepare`  | no      | yes (transitional)        | Stale datasets served via `serveTransitional`, fresh ones via `serveCurrent`. |
| `finalize` | yes     | yes (final)               | Build/download stale datasets, delete unlisted ones, serve all via `serveCurrent`. |

`prepare` lets the tile server keep serving (from the CDN, possibly via a live VPL) with no downtime
while `finalize` rebuilds in the background. See `../bin/update.sh` for the full two-phase
orchestration.

## Exit codes

| Code | Meaning                                                       |
| ---- | ------------------------------------------------------------ |
| `0`  | At least one dataset needs updating (or `finalize` completed). |
| `1`  | Pipeline error — abort.                                      |
| `2`  | Nothing to update (only emitted in `check` / `prepare`).    |

`bin/update.sh` uses exit `2` to skip the intermediate tile-server restart and the `finalize` phase.

## Pipeline (`update-tiles.sh`)

1. **Resolve** — fetch the CDN MD5 of every input (across all `versionInputs`) with `curl`.
2. **Compare** — compute each dataset's marker and diff it against the local `.md5` sidecar.
3. **Build** (`finalize` only) — clean up temp files, delete `.versatiles` files no longer in the
   manifest, then for each stale dataset run its `build`:
   - **mirror:** download with `aria2c` (16 parallel connections, inline `--checksum=md5=…`, atomic
     temp → rename), or
   - **vpl:** delete the old artifact first (disk can't hold two copies; in the two-phase flow the
     server is already serving via `serveTransitional`), then `versatiles convert "[,vpl](pipeline)"`.

   Write the `.md5` marker afterwards.
4. **Generate** — write `versatiles.yaml` atomically, plus any `serveCurrent`/`serveTransitional`
   `.vpl` files (also atomic); prune stale `.vpl` files.

## Configuration

| Variable        | Default                        | Purpose                                                  |
| --------------- | ------------------------------ | -------------------------------------------------------- |
| `CDN_BASE_URL`  | `https://cdn.versatiles.cloud` | CDN hosting the `.versatiles` files and `.md5` sidecars. |
| `VOLUME_FOLDER` | `/volumes`                     | Root containing `tiles/` and `versatiles_conf/`.         |
| `MANIFEST`      | `<script dir>/sources.json`    | Path to the source manifest.                             |

## Volume mounts

| Host path                   | Container path             | Purpose                                          |
| --------------------------- | -------------------------- | ------------------------------------------------ |
| `./volumes/tiles`           | `/volumes/tiles`           | Tile files + their `.md5` sidecars (rw).         |
| `./volumes/versatiles_conf` | `/volumes/versatiles_conf` | Generated `versatiles.yaml` and `.vpl` files (rw). |

The container runs as UID 1001, so both volumes must be owned by `1001:1001` (handled by
`bin/deploy/ensure.sh`).
