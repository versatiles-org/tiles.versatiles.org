/**
 * Hash utilities for `.versatiles` files.
 *
 * Downloads existing MD5 and SHA256 hash files from remote storage via SSH.
 * If hash files don't exist on remote, calculates them remotely via SSH.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'fs';
import { basename, dirname, join } from 'path';
import { FileRef } from './file_ref.js';
import { spawnSync } from 'child_process';

/** Local cache directory for hash files */
const HASH_CACHE_DIR = '/volumes/local_files/.hash_cache';

/**
 * Gets the local cache path for a hash file.
 */
function getHashCachePath(remotePath: string, hashType: string): string {
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
 * Runs an SSH command and returns stdout, ignoring common warnings.
 */
function sshCommand(args: string[]): { success: boolean; stdout: string } {
	const storageUrl = process.env['STORAGE_URL'];
	if (!storageUrl) throw new Error('STORAGE_URL not set');

	const fullArgs = [
		storageUrl,
		'-p', '23',
		'-i', '/app/.ssh/storage',
		'-oBatchMode=yes',
		'-oStrictHostKeyChecking=accept-new',
		...args
	];

	const result = spawnSync('ssh', fullArgs);

	return {
		success: result.status === 0,
		stdout: result.stdout.toString().trim()
	};
}

/**
 * Downloads a hash file from remote storage via SSH.
 * Returns the hash string or null if not found.
 */
function downloadHashFile(remotePath: string, hashType: string): string | null {
	const remoteHashPath = `${remotePath}.${hashType}`;
	const result = sshCommand(['cat', remoteHashPath]);

	if (!result.success || result.stdout.length === 0) {
		return null;
	}

	// Parse hash from output: "<hash>  filename" or "<hash> filename"
	const hash = result.stdout.split(/\s/)[0];
	return (hash && hash.length >= 32) ? hash : null;
}

/**
 * Calculates a hash on the remote server via SSH.
 * Returns the hash string or null on failure.
 */
function calculateHashRemote(remotePath: string, hashType: string): string | null {
	console.log(`   Calculating ${hashType} for ${basename(remotePath)} on remote...`);
	const result = sshCommand([`${hashType}sum`, remotePath]);

	if (!result.success || result.stdout.length === 0) {
		return null;
	}

	// Parse hash from output: "<hash>  /path/to/file"
	const hash = result.stdout.split(/\s/)[0];
	return (hash && hash.length >= 32) ? hash : null;
}

/**
 * Gets hash for a file - tries to download existing, falls back to calculating.
 */
function getHash(remotePath: string, hashType: string): string {
	// First try to download existing hash file
	let hash = downloadHashFile(remotePath, hashType);

	// If not found, calculate on remote
	if (!hash) {
		hash = calculateHashRemote(remotePath, hashType);
	}

	if (!hash) {
		throw new Error(`Failed to get ${hashType} hash for ${remotePath}`);
	}

	return hash;
}

/**
 * Downloads and caches hashes for all files from remote storage.
 * Uses existing .md5 and .sha256 files on the remote, or calculates if missing.
 */
export async function generateHashes(files: FileRef[]) {
	// Ensure cache directory exists
	if (!existsSync(HASH_CACHE_DIR)) {
		mkdirSync(HASH_CACHE_DIR, { recursive: true });
	}

	console.log('Fetching hashes from remote storage...');

	let downloaded = 0;
	let calculated = 0;
	let cached = 0;

	for (const file of files) {
		for (const hashType of ['md5', 'sha256'] as const) {
			const cachePath = getHashCachePath(file.remotePath, hashType);

			if (existsSync(cachePath)) {
				cached++;
				continue;
			}

			ensureCacheDir(cachePath);

			// Try download first, then calculate
			let hash = downloadHashFile(file.remotePath, hashType);
			if (hash) {
				downloaded++;
			} else {
				hash = calculateHashRemote(file.remotePath, hashType);
				if (hash) {
					calculated++;
				} else {
					throw new Error(`Failed to get ${hashType} hash for ${file.remotePath}`);
				}
			}

			writeFileSync(cachePath, `${hash} ${basename(file.remotePath)}\n`);
		}
	}

	console.log(` - ${downloaded} downloaded, ${calculated} calculated, ${cached} cached`);

	// Read all hashes from cache
	console.log('Reading hashes from cache...');
	for (const file of files) {
		file.hashes = {
			md5: readHash(file.remotePath, 'md5'),
			sha256: readHash(file.remotePath, 'sha256'),
		};
	}
}

/**
 * Reads a cached hash file and returns just the hash value.
 */
function readHash(remotePath: string, hashType: string): string {
	const cachePath = getHashCachePath(remotePath, hashType);
	const content = readFileSync(cachePath, 'utf8');
	return content.split(/\s/)[0];
}
