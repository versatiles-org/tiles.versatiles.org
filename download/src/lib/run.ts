/**
 * Orchestrates the tile-data update pipeline for the VersaTiles tile server.
 *
 * Mirrors the `.versatiles` files from the CDN (cdn.versatiles.cloud) into the
 * local `tiles/` volume and (re)generates `versatiles.yaml` so the tile server
 * always has a current config. Downloads use aria2c with parallel connections.
 *
 * The `run()` function supports three modes:
 *
 * **prepare** (safe update phase 1):
 * - Fetches each dataset's MD5 from the CDN and checks local state without
 *   downloading anything.
 * - Generates `versatiles.yaml` with CDN URLs for stale/missing datasets and
 *   local paths for datasets that are already current, so the tile server can
 *   keep serving stale tilesets from the CDN while finalize downloads them.
 * - Returns `true` if any dataset needs updating, `false` otherwise.
 *
 * **finalize** (safe update phase 2, default):
 * - Downloads stale/missing datasets via aria2c, deletes datasets no longer
 *   listed, and generates `versatiles.yaml` pointing entirely to local disk.
 *
 * **check**: read-only — fetch MD5s, check local state, return whether anything
 * needs updating. Writes nothing.
 */
import { resolve } from 'path';
import { resolveDatasets, checkLocalFiles, downloadLocalFiles } from './sync.js';
import { generateVersatilesYaml } from './versatiles_yaml.js';

/**
 * Configuration options for the `run()` pipeline.
 *
 * - `volumeFolder`: root folder containing the expected subdirectories:
 *   - `tiles/` — tile data (*.versatiles files)
 *   - `versatiles_conf/` — output location for the generated versatiles.yaml
 * - `mode`: controls which phase of the safe update pipeline to run
 *   (`'check'` | `'prepare'` | `'finalize'`, default `'finalize'`).
 *
 * When `volumeFolder` is not provided, a default `/volumes/` folder is used
 * (the standard mount point inside the Docker container).
 */
export interface Options {
	volumeFolder?: string;
	mode?: 'check' | 'prepare' | 'finalize';
}

/**
 * Executes the tile-data update pipeline. Returns `true` if any dataset needs
 * updating (only meaningful in `check`/`prepare`); `finalize` always ends with
 * a fully-local state and returns `false`.
 *
 * Throws if a CDN request fails or any downstream step fails.
 */
export async function run(options: Options = {}): Promise<boolean> {
	const volumeFolder = options.volumeFolder ?? '/volumes';
	const tilesFolder = resolve(volumeFolder, 'tiles');
	const versatilesConfFolder = resolve(volumeFolder, 'versatiles_conf');
	const mode = options.mode ?? 'finalize';

	// Fetch the current MD5 of every dataset from the CDN.
	const states = await resolveDatasets();

	let needsUpdate = false;
	if (mode === 'check' || mode === 'prepare') {
		// Check local state without downloading; stale datasets stay isRemote=true.
		needsUpdate = checkLocalFiles(states, tilesFolder);
	} else {
		// Download stale/missing datasets; all end up local (isRemote=false).
		await downloadLocalFiles(states, tilesFolder);
	}

	// Read-only check mode: report status without writing any config.
	if (mode === 'check') return needsUpdate;

	// Generate versatiles.yaml for the tile server.
	generateVersatilesYaml(states, resolve(versatilesConfFolder, 'versatiles.yaml'));

	return needsUpdate;
}
