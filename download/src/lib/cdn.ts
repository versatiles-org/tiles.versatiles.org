/**
 * Helpers for talking to the CDN that hosts the `.versatiles` files.
 *
 * The files live behind a Cloudflare bucket (default `cdn.versatiles.cloud`):
 * each dataset is a stable object key `<slug>.versatiles` plus a small
 * `<slug>.versatiles.md5` checksum sidecar, served over HTTPS with range
 * support. Bytes are fetched with aria2c using many parallel connections;
 * checksums are fetched with `fetch`.
 */
import { spawnSync } from 'child_process';
import { basename, dirname, join } from 'path';
import { renameSync } from 'fs';

/** Base URL of the CDN hosting the `.versatiles` files and their `.md5` sidecars. */
export function cdnBaseUrl(): string {
	return (process.env['CDN_BASE_URL'] ?? 'https://cdn.versatiles.cloud').replace(/\/+$/, '');
}

/** Fetches a small text resource (e.g. an `.md5` sidecar) over HTTPS. */
export async function fetchText(url: string): Promise<string> {
	const response = await fetch(url);
	if (!response.ok) throw new Error(`GET ${url} failed: HTTP ${response.status}`);
	return (await response.text()).trim();
}

/** Extracts the leading hash token from a checksum-file body (`<hash>  <filename>`). */
export function parseHash(body: string): string {
	const hash = body.split(/\s/)[0];
	if (!hash || hash.length < 32) throw new Error(`invalid checksum body: "${body.slice(0, 48)}"`);
	return hash;
}

/**
 * Downloads `url` to `destPath` using aria2c with parallel connections,
 * verifying the expected MD5 during the transfer. Writes to a temporary file
 * (`<name>.download`) and renames atomically on success; on failure the temp
 * file is left in place (caller cleans up stale temp files before retrying).
 */
export function downloadWithAria2c(url: string, destPath: string, expectedMd5: string): void {
	const dir = dirname(destPath);
	const finalName = basename(destPath);
	const tempName = `${finalName}.download`;

	const args = [
		`--dir=${dir}`,
		`--out=${tempName}`,
		'--max-connection-per-server=16',
		'--split=16',
		'--min-split-size=10M',
		'--max-tries=5',
		'--retry-wait=5',
		'--continue=true',
		'--allow-overwrite=true',
		'--auto-file-renaming=false',
		`--checksum=md5=${expectedMd5}`,
		'--console-log-level=warn',
		'--summary-interval=0',
		url,
	];

	const result = spawnSync('aria2c', args, { stdio: 'inherit' });
	if (result.status !== 0) {
		throw new Error(`aria2c failed for ${url} (exit ${result.status ?? 'signal'})`);
	}

	renameSync(join(dir, tempName), destPath);
}
