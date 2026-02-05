/**
 * Utilities for generating the final NGINX configuration used by
 * download.versatiles.org.
 *
 * The configuration is produced from a Handlebars template (`template/nginx.conf`)
 * and populated with:
 * - `files`: the list of all public `FileRef`s (real and generated)
 * - `responses`: virtual inline responses such as checksum files or URL lists
 * - `webhook`: optional webhook endpoint injected via the `WEBHOOK` env variable
 *
 * The result is a complete NGINX config that defines:
 * - static file locations
 * - small synthetic endpoints (from `FileResponse`)
 * - optional `/update` endpoint when running inside the update container
 */
import { readFileSync, writeFileSync } from 'fs';
import Handlebars from 'handlebars';
import { FileRef } from '../file/file_ref.js';
import { FileResponse } from '../file/file_response.js';

/**
 * Builds the full NGINX configuration as a string.
 *
 * Steps:
 * - Loads and compiles the Handlebars template `template/nginx.conf`.
 * - Sorts `files` and `responses` by URL to ensure deterministic output.
 * - Injects environment variable `WEBHOOK` into the template if present.
 *
 * Returns the rendered NGINX configuration.
 */
export function buildNginxConf(files: FileRef[], responses: FileResponse[]): string {
	const templateFilename = new URL('../../../template/nginx.conf', import.meta.url).pathname;
	const templateContent = readFileSync(templateFilename, 'utf-8');
	const template = Handlebars.compile(templateContent);

	const webhook = process.env['WEBHOOK'];
	const domain = process.env['DOMAIN'];

	files.sort((a, b) => a.url.localeCompare(b.url));
	responses.sort((a, b) => a.url.localeCompare(b.url));

	// Compile the NGINX configuration using Handlebars and the provided files
	return template({ files, responses, webhook, domain });
}

/**
 * Generates the NGINX configuration and writes it to disk.
 *
 * This function is a thin wrapper around `buildNginxConf()`. It renders the
 * configuration and writes it to `filename`, overwriting any existing file.
 *
 * Logs progress to stdout for visibility during build steps.
 */
export function generateNginxConf(files: FileRef[], responses: FileResponse[], filename: string) {
	console.log('Generating NGINX configuration...');

	// Write the generated configuration to the specified filename
	writeFileSync(filename, buildNginxConf(files, responses));
	console.log(' - Configuration successfully written');
}
