/**
 * Orchestrates the full update pipeline for download.versatiles.org.
 *
 * The `run()` function:
 * - discovers all `.versatiles` files in remote storage via SSH
 * - generates or loads checksum hashes for each file
 * - groups files into logical `FileGroup`s with metadata
 * - mirrors selected "local" files for high-speed download
 * - renders HTML (`index.html`) and RSS feeds for all groups
 * - prepares the list of public files and inline responses
 * - writes the final NGINX configuration with WebDAV proxy for remote files
 *
 * This module is the single entry point for both one-shot updates (`run_once.ts`)
 * and the HTTP-triggered update endpoint (`server.ts`).
 */
import { resolve } from 'path';
import { getRemoteFilesViaSSH } from './file/file_ref.js';
import { collectFiles, groupFiles } from './file/file_group.js';
import { generateHashes } from './file/hashes.js';
import { downloadLocalFiles } from './file/sync.js';
import { generateHTML, generateRSSFeeds } from './template/template.js';
import { generateNginxConf } from './nginx/nginx.js';
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
 *
 * When `volumeFolder` is not provided, a default `/volumes/` folder is used
 * (this is the standard mount point inside the Docker container).
 */
export interface Options {
	domain?: string;
	volumeFolder?: string;
}

/**
 * Executes the full site update pipeline.
 *
 * Steps:
 * 1. Resolve `volumeFolder`, `tilesFolder`, `contentFolder`, and `nginxFolder`.
 * 2. Resolve `domain` from `options.domain` or the `DOMAIN` environment variable.
 * 3. Discover all `.versatiles` files in remote storage via SSH.
 * 4. Generate or load MD5/SHA256 hashes for each file (cached locally).
 * 5. Group files into `FileGroup`s and derive metadata.
 * 6. Mirror "local" files (latest OSM) into `tilesFolder`.
 * 7. Generate `index.html` and per-group RSS feeds into `contentFolder`.
 * 8. Build the list of public `FileRef`s (local files + remote files).
 * 9. Derive all `FileResponse`s for synthetic endpoints.
 * 10. Render and write the NGINX configuration with WebDAV proxy.
 *
 * Throws:
 * - If `domain` is missing (no `DOMAIN` env and no `options.domain` provided).
 * - If no remote files are found.
 * - If any downstream step fails.
 */
export async function run(options: Options = {}) {
	// Define key folder paths
	const volumeFolder = options.volumeFolder ?? '/volumes';
	const tilesFolder = resolve(volumeFolder, 'tiles');
	const contentFolder = resolve(volumeFolder, 'content');
	const nginxFolder = resolve(volumeFolder, 'nginx_conf');

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

	// Download "local" files (latest versions of local groups like OSM)
	await downloadLocalFiles(fileGroups, tilesFolder);

	// Collect all files for nginx configuration
	// - Local files (synced to tiles/ or content/) use alias
	// - Remote files use WebDAV proxy
	const publicFiles = collectFiles(
		fileGroups,
		generateHTML(fileGroups, resolve(contentFolder, 'index.html')),
		generateRSSFeeds(fileGroups, contentFolder),
	).map(f => {
		const cloned = f.clone();
		// Update fullname for local files to container path
		if (!cloned.isRemote) {
			cloned.fullname = cloned.fullname.replace(volumeFolder, '/volumes');
		}
		return cloned;
	});

	const publicResponses: FileResponse[] = fileGroups.flatMap(f => f.getResponses(baseURL));

	// Generate NGINX configuration with WebDAV proxy support
	const confFilename = resolve(nginxFolder, 'download.conf');
	generateNginxConf(publicFiles, publicResponses, confFilename);
}
