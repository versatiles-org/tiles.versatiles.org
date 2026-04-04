/**
 * Orchestrates the full update pipeline for download.versatiles.org.
 *
 * The `run()` function supports two modes:
 *
 * **prepare** (safe update phase 1):
 * - Discovers files and checks local state without downloading anything.
 * - Generates `versatiles.yaml` with WebDAV URLs for stale/missing files
 *   and local paths for files that are already current.
 * - Generates the NGINX configuration with the same local/remote split.
 * - Returns `true` if any files need updating (caller should restart
 *   VersaTiles so it serves stale tilesets from WebDAV, then call finalize).
 * - Returns `false` if everything is already up-to-date.
 *
 * **finalize** (safe update phase 2, default):
 * - Deletes stale local files, downloads missing or changed files.
 * - Generates `versatiles.yaml` and NGINX config pointing entirely to
 *   local disk.
 * - Generates the static site (HTML + RSS feeds).
 *
 * This module is the single entry point for both one-shot updates (`run_once.ts`)
 * and the HTTP-triggered update endpoint (`server.ts`).
 */
import { resolve } from 'path';
import { getRemoteFilesViaSSH } from './file/file_ref.js';
import { collectFiles, groupFiles } from './file/file_group.js';
import { generateHashes } from './file/hashes.js';
import { checkLocalFiles, downloadLocalFiles } from './file/sync.js';
import { generateSite } from './template/template.js';
import { generateNginxConf } from './nginx/nginx.js';
import { generateVersatilesYaml } from './versatiles_yaml.js';
import { FileResponse } from './file/file_response.js';

/**
 * Configuration options for the `run()` pipeline.
 *
 * - `domain`: public domain name used to construct absolute URLs
 *   (falls back to the `DOMAIN` environment variable when omitted).
 * - `volumeFolder`: root folder containing the expected subdirectories:
 *   - `tiles/` — tile data (*.versatiles files)
 *   - `content/` — generated HTML and RSS feeds
 *   - `nginx_conf/` — output location for the generated NGINX config
 *   - `versatiles_conf/` — output location for the generated versatiles.yaml
 * - `mode`: controls which phase of the safe update pipeline to run.
 *   - `'prepare'`: check local state, generate transitional configs (no download).
 *   - `'finalize'`: download updates, generate final configs. (default)
 *
 * When `volumeFolder` is not provided, a default `/volumes/` folder is used
 * (this is the standard mount point inside the Docker container).
 */
export interface Options {
	domain?: string;
	volumeFolder?: string;
	mode?: 'prepare' | 'finalize';
}

/**
 * Executes the site update pipeline.
 *
 * In **prepare** mode:
 * 1. Resolve folder paths and domain.
 * 2. Discover all `.versatiles` files in remote storage via SSH.
 * 3. Generate or load MD5/SHA256 hashes.
 * 4. Group files into `FileGroup`s.
 * 5. Check which local files are current (`checkLocalFiles`); stale/missing
 *    files keep `isRemote = true`.
 * 6. Generate static site (HTML + RSS).
 * 7. Build public file list and inline responses.
 * 8. Write NGINX config (stale files → WebDAV proxy).
 * 9. Write `versatiles.yaml` (stale files → WebDAV URL).
 * Returns `true` if any file needs updating, `false` if all are current.
 *
 * In **finalize** mode (default):
 * 1–4. Same as prepare.
 * 5. Download stale/missing files (`downloadLocalFiles`); all end up local.
 * 6–8. Same as prepare.
 * 9. Write `versatiles.yaml` (all files → local paths).
 * Returns `false` (always produces final local state).
 *
 * Throws:
 * - If `domain` is missing (no `DOMAIN` env and no `options.domain` provided).
 * - If no remote files are found.
 * - If any downstream step fails.
 */
export async function run(options: Options = {}): Promise<boolean> {
	// Define key folder paths
	const volumeFolder = options.volumeFolder ?? '/volumes';
	const tilesFolder = resolve(volumeFolder, 'tiles');
	const contentFolder = resolve(volumeFolder, 'content');
	const nginxFolder = resolve(volumeFolder, 'nginx_conf');
	const versatilesConfFolder = resolve(volumeFolder, 'versatiles_conf');

	const mode = options.mode ?? 'finalize';

	// Get the domain from environment variables
	const domain = options.domain ?? process.env['DOMAIN'];
	if (domain == null) throw Error('missing $DOMAIN');
	const baseURL = `https://${domain}/`;

	// Scan remote storage via SSH to get list of all .versatiles files
	const files = getRemoteFilesViaSSH();

	if (files.length === 0) throw Error('no remote files found');

	// Generate hashes for the files (computed via SSH, cached locally)
	await generateHashes(files);

	// Group files based on their names
	const fileGroups = groupFiles(files);

	let needsUpdate = false;

	if (mode === 'prepare') {
		// Check local state without downloading; stale files stay isRemote=true
		needsUpdate = checkLocalFiles(fileGroups, tilesFolder);
	} else {
		// Download stale/missing files; all end up with isRemote=false
		await downloadLocalFiles(fileGroups, tilesFolder);
	}

	// Generate static site (HTML + RSS feeds)
	const { htmlRef, rssRefs } = generateSite(fileGroups, contentFolder);

	// Collect all files for nginx configuration
	// - Local files (synced to tiles/ or content/) use alias
	// - Remote files use WebDAV proxy
	const publicFiles = collectFiles(fileGroups, htmlRef, rssRefs).map((f) => {
		const cloned = f.clone();
		// Update fullname for local files to container path
		if (!cloned.isRemote) {
			cloned.fullname = cloned.fullname.replace(volumeFolder, '/volumes');
		}
		return cloned;
	});

	const publicResponses: FileResponse[] = fileGroups.flatMap((f) => f.getResponses(baseURL));

	// Generate NGINX configuration with WebDAV proxy support
	const confFilename = resolve(nginxFolder, 'download.conf');
	generateNginxConf(publicFiles, publicResponses, confFilename);

	// Generate versatiles.yaml for the tile server
	const versatilesYamlPath = resolve(versatilesConfFolder, 'versatiles.yaml');
	generateVersatilesYaml(fileGroups, versatilesYamlPath);

	return needsUpdate;
}
