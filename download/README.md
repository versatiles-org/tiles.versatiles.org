# download-updater

Discovers `.versatiles` tile files on a remote storage box (via SSH), generates integrity hashes, mirrors selected files locally, and produces a static download site with NGINX configuration.

## Pipeline

The update pipeline (`run.ts`) executes the following steps in order:

1. **Discover** remote `.versatiles` files via `ssh ls -lR`
2. **Hash** each file (MD5 + SHA256)
3. **Group** files by name into `FileGroup`s
4. **Sync** the latest file of each "local" group to `/volumes/tiles/`
5. **Generate** static site (HTML + RSS) and NGINX config

## Hashing

Each remote file needs an MD5 and SHA256 hash for integrity checks and for serving `.md5`/`.sha256` files to users via NGINX.

For each file and hash type, `generateHashes()` tries the following in order:

1. **Local download cache** (`/volumes/download/hash_cache/`) — if a cached hash file exists, use it immediately.
2. **Remote hash file** (`<remotePath>.md5`/`.sha256`) — download via `ssh cat`. If found, cache it locally.
3. **Calculate on remote** — run `md5sum`/`sha256sum` via SSH, then store the result both on the remote (as `<remotePath>.<hashType>`) and in the local download cache.

This means the first run calculates hashes and stores them on remote. Subsequent runs download the pre-computed hash files.

## Syncing

`downloadLocalFiles()` mirrors the latest file from each "local" `FileGroup` into `/volumes/tiles/`.

The sync uses **hash-based comparison** (not file size) to detect changes:

- **Delete phase**: Files in `/volumes/tiles/` that are no longer wanted are deleted, along with their `.md5` and `.sha256` hash files.
- **Keep/download phase**: For each wanted file, the local MD5 hash file (`/volumes/tiles/<file>.md5`) is compared with the remote hash from `generateHashes()`. If they match, the file is kept. Otherwise it is re-downloaded via SCP, and local hash files are written for future comparisons.

## Volume Mounts

| Host path                       | Container path                 | Purpose                                              |
| ------------------------------- | ------------------------------ | ---------------------------------------------------- |
| `./volumes/tiles`               | `/volumes/tiles`               | Local tile files + their `.md5`/`.sha256` hash files |
| `./volumes/download/hash_cache` | `/volumes/download/hash_cache` | Download cache for remote hashes                     |
| `./volumes/download/content`    | `/volumes/content`             | Generated HTML + RSS                                 |
| `./volumes/download/nginx_conf` | `/volumes/nginx_conf`          | Generated NGINX config                               |
