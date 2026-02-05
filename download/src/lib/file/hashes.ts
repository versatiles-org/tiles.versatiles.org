/**
 * Hash generation utilities for `.versatiles` files.
 *
 * This module ensures that each file in the remote storage has associated
 * MD5 and SHA256 checksums. Missing hashes are computed over SSH on the
 * remote host and cached locally.
 *
 * Workflow:
 * - For every `FileRef`, check whether cached hashes exist locally.
 * - For missing hashes, execute `{md5,sha256}sum` remotely via SSH.
 * - Store the resulting checksum in a local cache file.
 * - Assign all hash values to `file.hashes`.
 *
 * Requirements:
 * - Environment variable `STORAGE_URL` must contain the SSH user@host.
 * - SSH identity `.ssh/storage` must exist in the container environment.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'fs';
import { basename, dirname, join } from 'path';
import { FileRef } from './file_ref.js';
import { ProgressBar } from 'work-faster';
import { spawnSync } from 'child_process';

/** Local cache directory for hash files */
const HASH_CACHE_DIR = '/volumes/local_files/.hash_cache';

/**
 * Gets the local cache path for a hash file.
 * Organizes by remote path structure to avoid collisions.
 */
function getHashCachePath(remotePath: string, hashType: string): string {
	// Convert /home/osm/file.versatiles to osm/file.versatiles
	const relativePath = remotePath.replace(/^\/home\//, '');
	return join(HASH_CACHE_DIR, relativePath + '.' + hashType);
}

/**
 * Ensures cache directory exists for a given path.
 */
function ensureCacheDir(cachePath: string): void {
	const dir = dirname(cachePath);
	if (!existsSync(dir)) {
		mkdirSync(dir, { recursive: true });
	}
}

/**
 * Ensures that all provided files have MD5 and SHA256 checksums.
 *
 * For each file:
 * - If cached hash exists locally, use it.
 * - Otherwise, compute remotely via SSH and cache locally.
 *
 * After processing, every file receives `file.hashes = { md5, sha256 }`.
 */
export async function generateHashes(files: FileRef[]) {
	/** List of (file, hashName) tasks that must be computed remotely. */
	const todos: { file: FileRef, hashName: string }[] = [];

	// Ensure cache directory exists
	if (!existsSync(HASH_CACHE_DIR)) {
		mkdirSync(HASH_CACHE_DIR, { recursive: true });
	}

	console.log('Checking hashes...');
	files.forEach(file => {
		const md5CachePath = getHashCachePath(file.remotePath, 'md5');
		if (!existsSync(md5CachePath)) {
			todos.push({ file, hashName: 'md5' });
		}

		const sha256CachePath = getHashCachePath(file.remotePath, 'sha256');
		if (!existsSync(sha256CachePath)) {
			todos.push({ file, hashName: 'sha256' });
		}
	});

	/**
	 * Compute missing hashes remotely and cache locally.
	 */
	if (todos.length > 0) {
		console.log(` - Calculating ${todos.length} missing hashes...`);

		const sum = todos.reduce((s, t) => s + t.file.size, 0);
		const progress = new ProgressBar(sum);

		const storageUrl = process.env['STORAGE_URL'];
		if (!storageUrl) throw new Error('STORAGE_URL environment variable is not set');

		for (const todo of todos) {
			const { file, hashName } = todo;
			const cachePath = getHashCachePath(file.remotePath, hashName);

			ensureCacheDir(cachePath);

			const args = [
				storageUrl,
				'-p', '23',
				'-i', '/app/.ssh/storage',
				'-oBatchMode=yes',
				'-oStrictHostKeyChecking=accept-new',
				hashName + 'sum',
				file.remotePath
			];

			const result = spawnSync('ssh', args);
			if (result.stderr.length > 0) {
				const stderr = result.stderr.toString();
				// Ignore host key warnings
				if (!stderr.includes('Warning:') && !stderr.includes('Permanently added')) {
					throw Error(`SSH error for ${file.filename}: ${stderr}`);
				}
			}

			// Parse hash from output: "<hash>  /path/to/file"
			const output = result.stdout.toString();
			const hash = output.split(/\s/)[0];

			if (!hash || hash.length < 32) {
				throw new Error(`Invalid hash output for ${file.filename}: ${output}`);
			}

			// Store hash with filename format: "<hash> <filename>"
			writeFileSync(cachePath, `${hash} ${basename(file.remotePath)}\n`);
			progress.increment(file.size);
		}
	}

	console.log('Reading hashes...');
	files.forEach(f => {
		f.hashes = {
			md5: readHash(f.remotePath, 'md5'),
			sha256: readHash(f.remotePath, 'sha256'),
		};
	});
}

/**
 * Reads a cached hash file and returns just the hash value.
 */
function readHash(remotePath: string, hashType: string): string {
	const cachePath = getHashCachePath(remotePath, hashType);
	const content = readFileSync(cachePath, 'utf8');
	return content.split(/\s/)[0];
}
