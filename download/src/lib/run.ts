/**
 * Orchestrates the tile-data update pipeline for the VersaTiles tile server.
 *
 * Mirrors the `.versatiles` files from the remote Hetzner storage box into the
 * local `tiles/` volume and (re)generates `versatiles.yaml` so the tile server
 * always has a current config. The public download site that used to live here
 * has moved to download.versatiles.org (served from Cloudflare R2); this
 * pipeline no longer generates any website or nginx download config.
 *
 * The `run()` function supports three modes:
 *
 * **prepare** (safe update phase 1):
 * - Discovers files and checks local state without downloading anything.
 * - Generates `versatiles.yaml` with download.versatiles.org URLs for
 *   stale/missing files and local paths for files that are already current, so
 *   the tile server can keep serving stale tilesets from the public download
 *   site while finalize downloads them.
 * - Returns `true` if any files need updating, `false` otherwise.
 *
 * **finalize** (safe update phase 2, default):
 * - Deletes stale local files, downloads missing or changed files.
 * - Generates `versatiles.yaml` pointing entirely to local disk.
 *
 * **check**: read-only — discover files, check local state, return whether
 * anything needs updating. Writes nothing.
 */
import { resolve } from 'path';
import { getRemoteFilesViaSSH } from './file/file_ref.js';
import { groupFiles } from './file/file_group.js';
import { generateHashes } from './file/hashes.js';
import { checkLocalFiles, downloadLocalFiles } from './file/sync.js';
import { generateVersatilesYaml } from './versatiles_yaml.js';

/**
 * Configuration options for the `run()` pipeline.
 *
 * - `volumeFolder`: root folder containing the expected subdirectories:
 *   - `tiles/` — tile data (*.versatiles files)
 *   - `versatiles_conf/` — output location for the generated versatiles.yaml
 * - `mode`: controls which phase of the safe update pipeline to run.
 *   - `'check'`:    read-only — discover files, check local state, return
 *                   whether anything needs updating. No downloads, no
 *                   config writes.
 *   - `'prepare'`:  check local state, generate transitional versatiles.yaml
 *                   (no download). Used by update.sh phase 1.
 *   - `'finalize'`: download updates, generate final versatiles.yaml. (default)
 *
 * When `volumeFolder` is not provided, a default `/volumes/` folder is used
 * (this is the standard mount point inside the Docker container).
 */
export interface Options {
	volumeFolder?: string;
	mode?: 'check' | 'prepare' | 'finalize';
}

/**
 * Executes the tile-data update pipeline.
 *
 * In **check** mode:
 * 1. Discover all `.versatiles` files in remote storage via SSH.
 * 2. Generate or load MD5/SHA256 hashes.
 * 3. Group files into `FileGroup`s.
 * 4. Check which local files are current (`checkLocalFiles`).
 * Returns `true` if any file needs updating, `false` if all are current.
 * Writes nothing.
 *
 * In **prepare** mode:
 * 1–4. Same as check.
 * 5. Write `versatiles.yaml` (stale files → download.versatiles.org URL, current files → local).
 * Returns `true` if any file needs updating, `false` if all are current.
 *
 * In **finalize** mode (default):
 * 1–3. Same as check.
 * 4. Download stale/missing files (`downloadLocalFiles`); all end up local.
 * 5. Write `versatiles.yaml` referencing local files only.
 * Returns `false` (always produces final local state).
 *
 * Throws:
 * - If no remote files are found.
 * - If any downstream step fails.
 */
export async function run(options: Options = {}): Promise<boolean> {
	// Define key folder paths
	const volumeFolder = options.volumeFolder ?? '/volumes';
	const tilesFolder = resolve(volumeFolder, 'tiles');
	const versatilesConfFolder = resolve(volumeFolder, 'versatiles_conf');

	const mode = options.mode ?? 'finalize';

	// Scan remote storage via SSH to get list of all .versatiles files
	const files = getRemoteFilesViaSSH();

	if (files.length === 0) throw Error('no remote files found');

	// Generate hashes for the files (computed via SSH, cached locally)
	await generateHashes(files);

	// Group files based on their names
	const fileGroups = groupFiles(files);

	let needsUpdate = false;

	if (mode === 'check' || mode === 'prepare') {
		// Check local state without downloading; stale files stay isRemote=true
		needsUpdate = checkLocalFiles(fileGroups, tilesFolder);
	} else {
		// Download stale/missing files; all end up with isRemote=false
		await downloadLocalFiles(fileGroups, tilesFolder);
	}

	// Read-only check mode: report status without writing any config.
	// Used by update.sh --dry-run.
	if (mode === 'check') return needsUpdate;

	// Generate versatiles.yaml for the tile server
	const versatilesYamlPath = resolve(versatilesConfFolder, 'versatiles.yaml');
	generateVersatilesYaml(fileGroups, versatilesYamlPath);

	return needsUpdate;
}
