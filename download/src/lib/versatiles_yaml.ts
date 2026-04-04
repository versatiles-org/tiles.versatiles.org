/**
 * Generates the `versatiles.yaml` configuration file for the VersaTiles tile server.
 *
 * Each `local` FileGroup's tile source is resolved to either:
 * - A local file path (`/data/tiles/filename.versatiles`) when the file is
 *   already present and up-to-date on disk (`isRemote === false`).
 * - An HTTPS/WebDAV URL (`https://user:pass@host/path`) when the file is
 *   missing or stale and needs to be fetched from remote storage
 *   (`isRemote === true`).
 *
 * This allows the VersaTiles server to start immediately on a fresh install
 * or during a file update, serving tiles from remote storage until the local
 * download completes.
 */
import { writeFileSync, renameSync, mkdirSync, existsSync } from 'fs';
import { dirname } from 'path';
import { FileGroup } from './file/file_group.js';

/**
 * Builds the `versatiles.yaml` configuration as a string.
 *
 * @param fileGroups - All FileGroups; only those with `local === true` and a
 *   `latestFile` are included as tile sources.
 */
export function buildVersatilesYaml(fileGroups: FileGroup[]): string {
	const storageUrl = process.env['STORAGE_URL'] ?? '';
	const storagePass = process.env['STORAGE_PASS'] ?? '';

	let webdavBaseUrl = '';
	if (storageUrl && storagePass) {
		// STORAGE_URL format: user@host
		const match = storageUrl.match(/^([^@]+)@(.+)$/);
		if (match) {
			const [, user, host] = match;
			webdavBaseUrl = `https://${user}:${storagePass}@${host}`;
		}
	}

	const tileEntries = fileGroups
		.filter((g) => g.local && g.latestFile)
		.map((g) => {
			const file = g.latestFile!;
			const src = file.isRemote
				? `${webdavBaseUrl}${file.webdavPath}`
				: `/data/tiles/${file.filename}`;
			return `  - name: ${g.slug}\n    src: ${src}`;
		})
		.join('\n');

	return `server:
  ip: "0.0.0.0"
  port: 8080

static:
  - src: /data/frontend/frontend.br.tar
  - src: /data/frontend/styles.tar
    prefix: /assets/styles

tiles:
${tileEntries}
`;
}

/**
 * Generates the `versatiles.yaml` configuration and writes it to disk atomically.
 * Uses temp file + rename to prevent partial writes.
 */
export function generateVersatilesYaml(fileGroups: FileGroup[], outputPath: string): void {
	console.log('Generating versatiles.yaml...');
	const dir = dirname(outputPath);
	if (!existsSync(dir)) {
		mkdirSync(dir, { recursive: true });
	}
	const tempPath = outputPath + '.tmp';
	writeFileSync(tempPath, buildVersatilesYaml(fileGroups));
	renameSync(tempPath, outputPath);
	console.log(' - versatiles.yaml successfully written');
}
