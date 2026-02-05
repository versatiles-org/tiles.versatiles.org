/**
 * Orchestrates the full update pipeline for download.versatiles.org.
 *
 * The `run()` function:
 * - locates the volume folders (remote files, local files, nginx config)
 * - discovers all `.versatiles` files in remote storage
 * - generates or loads checksum hashes for each file
 * - groups files into logical `FileGroup`s with metadata
 * - mirrors selected "local" files into the local high-speed folder
 * - renders HTML (`index.html`) and RSS feeds for all groups
 * - prepares the list of public files and inline responses
 * - writes the final NGINX configuration
 *
 * This module is the single entry point for both one-shot updates (`run_once.ts`)
 * and the HTTP-triggered update endpoint (`server.ts`).
 */
import { resolve } from 'path';
import { getAllFilesRecursive } from './file/file_ref.js';
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
 *   - `remote_files/` — remote storage mount with `.versatiles` files
 *   - `local_files/` — local mirror used for high-speed download
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
 * 1. Resolve `volumeFolder`, `remoteFolder`, `localFolder`, and `nginxFolder`.
 * 2. Resolve `domain` from `options.domain` or the `DOMAIN` environment variable.
 * 3. Recursively discover all `.versatiles` files in `remoteFolder`.
 * 4. Generate or load MD5/SHA256 hashes for each file.
 * 5. Group files into `FileGroup`s and derive metadata.
 * 6. Mirror "local" files into `localFolder`.
 * 7. Generate `index.html` and per-group RSS feeds into `localFolder`.
 * 8. Build the list of public `FileRef`s (with container-relative paths).
 * 9. Derive all `FileResponse`s for synthetic endpoints.
 * 10. Render and write the NGINX configuration into `nginxFolder`.
 *
 * Throws:
 * - If `domain` is missing (no `DOMAIN` env and no `options.domain` provided).
 * - If no remote files are found in `remoteFolder`.
 * - If any downstream step fails (hashing, grouping, syncing, templating, nginx).
 */
export async function run(options: Options = {}) {
	// Define key folder paths for the volumes, remote, local files, and Nginx configuration.
	const volumeFolder = options.volumeFolder ?? '/volumes';
	const remoteFolder = resolve(volumeFolder, 'remote_files'); // Folder containing remote files.
	const localFolder = resolve(volumeFolder, 'local_files'); // Folder for downloaded local files.
	const nginxFolder = resolve(volumeFolder, 'nginx_conf'); // Folder for the generated Nginx config.

	// Get the domain from environment variables. Throw an error if it's not set.
	const domain = options.domain ?? process.env['DOMAIN'];
	if (domain == null) throw Error('missing $DOMAIN');
	const baseURL = `https://${domain}/`;

	// Get a list of all files in the remote folder recursively.
	const files = getAllFilesRecursive(remoteFolder);

	// If no remote files are found, throw an error.
	if (files.length === 0) throw Error('no remote files found');

	// Generate hashes for the files located in the remote folder.
	await generateHashes(files, remoteFolder);

	// Group files based on their names.
	const fileGroups = groupFiles(files);

	// Download remote files to the local folder if needed.
	await downloadLocalFiles(fileGroups, localFolder);

	// Collect files to generate public-facing resources, like HTML and file lists.
	const publicFiles = collectFiles(
		fileGroups,
		// `generateHTML` creates index.html and returns a FileRef
		generateHTML(fileGroups, resolve(localFolder, 'index.html')),
		generateRSSFeeds(fileGroups, resolve(localFolder)),
	).map(f => f.cloneMoved(volumeFolder, '/volumes/'));
	// FileRefs are cloned and their paths "moved" so they have to correct paths in the Nginx configuration

	const publicResponses: FileResponse[] = fileGroups.flatMap(f => f.getResponses(baseURL));

	// Generate an Nginx configuration file and save it.
	const confFilename = resolve(nginxFolder, 'download.conf');
	generateNginxConf(publicFiles, publicResponses, confFilename);
}
