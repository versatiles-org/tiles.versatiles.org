/**
 * Utilities for generating the final NGINX configuration used by
 * download.versatiles.org.
 *
 * The configuration is produced from a Handlebars template (`template/nginx.conf`)
 * and populated with:
 * - `localFiles`: files served from local storage (alias)
 * - `remoteFiles`: files served via WebDAV proxy
 * - `responses`: virtual inline responses such as checksum files or URL lists
 * - `webhook`: optional webhook endpoint for triggering updates
 * - `webdavAuth`: Base64-encoded credentials for WebDAV proxy
 * - `webdavHost`: WebDAV server hostname
 */
import { readFileSync, writeFileSync, renameSync } from 'fs';
import Handlebars from 'handlebars';
import { FileRef } from '../file/file_ref.js';
import { FileResponse } from '../file/file_response.js';

/**
 * Builds the full NGINX configuration as a string.
 */
export function buildNginxConf(files: FileRef[], responses: FileResponse[]): string {
	const templateFilename = new URL('../../../template/nginx.conf', import.meta.url).pathname;
	const templateContent = readFileSync(templateFilename, 'utf-8');
	const template = Handlebars.compile(templateContent);

	const webhook = process.env['WEBHOOK'];
	const domain = process.env['DOMAIN'];

	// Parse STORAGE_URL to get WebDAV host and user
	const storageUrl = process.env['STORAGE_URL'] ?? '';
	const storagePass = process.env['STORAGE_PASS'] ?? '';

	let webdavHost = '';
	let webdavAuth = '';

	if (storageUrl && storagePass) {
		// STORAGE_URL format: user@host
		const match = storageUrl.match(/^([^@]+)@(.+)$/);
		if (match) {
			const [, user, host] = match;
			webdavHost = host;
			// Create Base64-encoded Basic Auth header
			webdavAuth = Buffer.from(`${user}:${storagePass}`).toString('base64');
		}
	}

	// Separate local and remote files
	const localFiles = files.filter((f) => !f.isRemote);
	const remoteFiles = files.filter((f) => f.isRemote);

	// Sort for deterministic output
	localFiles.sort((a, b) => a.url.localeCompare(b.url));
	remoteFiles.sort((a, b) => a.url.localeCompare(b.url));
	responses.sort((a, b) => a.url.localeCompare(b.url));

	return template({
		localFiles,
		remoteFiles,
		responses,
		webhook,
		domain,
		webdavHost,
		webdavAuth,
	});
}

/**
 * Generates the NGINX configuration and writes it to disk atomically.
 * Uses temp file + rename to prevent partial writes.
 */
export function generateNginxConf(files: FileRef[], responses: FileResponse[], filename: string) {
	console.log('Generating NGINX configuration...');
	const tempFile = filename + '.tmp';
	writeFileSync(tempFile, buildNginxConf(files, responses));
	renameSync(tempFile, filename);
	console.log(' - Configuration successfully written');
}
