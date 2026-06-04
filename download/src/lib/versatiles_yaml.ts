/**
 * Generates the `versatiles.yaml` configuration for the VersaTiles tile server.
 *
 * Each dataset's tile source is resolved to either:
 * - A local file path (`/data/tiles/<slug>.versatiles`) when the file is
 *   present and current on disk (`isRemote === false`).
 * - A public CDN URL (`https://cdn.versatiles.cloud/<slug>.versatiles`) when the
 *   file is missing or stale and is still syncing locally (`isRemote === true`).
 *
 * The CDN fallback lets the tile server start immediately and stay available
 * during an update — without embedding any credentials.
 */
import { writeFileSync, renameSync, mkdirSync, existsSync } from 'fs';
import { dirname } from 'path';
import { cdnBaseUrl } from './cdn.js';
import { DatasetState } from './sync.js';

/**
 * Builds the `versatiles.yaml` configuration as a string.
 */
export function buildVersatilesYaml(states: DatasetState[]): string {
	const cdn = cdnBaseUrl();

	const tileEntries = states
		.map((state) => {
			const src = state.isRemote ? `${cdn}${state.url}` : `/data/tiles/${state.filename}`;
			return `  - name: ${state.slug}\n    src: ${src}`;
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
export function generateVersatilesYaml(states: DatasetState[], outputPath: string): void {
	console.log('Generating versatiles.yaml...');
	const dir = dirname(outputPath);
	if (!existsSync(dir)) {
		mkdirSync(dir, { recursive: true });
	}
	const tempPath = outputPath + '.tmp';
	writeFileSync(tempPath, buildVersatilesYaml(states));
	renameSync(tempPath, outputPath);
	console.log(' - versatiles.yaml successfully written');
}
