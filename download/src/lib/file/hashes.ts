/**
 * Hash utilities for `.versatiles` files.
 *
 * Downloads existing MD5 and SHA256 hash files from remote storage via SSH.
 * If hash files don't exist on remote, calculates them remotely via SSH.
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync, unlinkSync, rmSync } from 'fs';
import { basename, dirname, join } from 'path';
import { tmpdir } from 'os';
import { FileRef } from './file_ref.js';
import { spawnSync } from 'child_process';

/** Shared SSH connection options (without port flag, since SSH uses -p and SCP uses -P) */
const SSH_COMMON_OPTIONS = ['-i', '/app/.ssh/storage', '-oBatchMode=yes', '-oStrictHostKeyChecking=accept-new'];

/** Local cache directory for downloaded hash files */
const DOWNLOAD_HASH_CACHE_DIR = '/volumes/download/hash_cache';

/**
 * Gets the local cache path for a hash file.
 */
function getHashCachePath(remotePath: string, hashType: string): string {
	const relativePath = remotePath.replace(/^\/home\//, '');
	return join(DOWNLOAD_HASH_CACHE_DIR, relativePath + '.' + hashType);
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

	const fullArgs = [storageUrl, '-p', '23', ...SSH_COMMON_OPTIONS, ...args];

	const result = spawnSync('ssh', fullArgs, { timeout: 1_800_000 });

	if (result.status === null) {
		return { success: false, stdout: '' };
	}

	return {
		success: result.status === 0,
		stdout: result.stdout.toString().trim(),
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
	return hash && hash.length >= 32 ? hash : null;
}

/**
 * Uploads a file to remote storage via SCP.
 */
function scpUpload(localPath: string, remotePath: string): boolean {
	const storageUrl = process.env['STORAGE_URL'];
	if (!storageUrl) throw new Error('STORAGE_URL not set');

	const result = spawnSync('scp', ['-P', '23', ...SSH_COMMON_OPTIONS, localPath, `${storageUrl}:${remotePath}`]);

	return result.status === 0;
}

/**
 * Calculates a hash on the remote server via SSH and stores it on remote via SCP.
 * Returns the hash string or throws on failure.
 */
function calculateHashRemote(remotePath: string, hashType: string): string {
	console.log(`   Calculating ${hashType} for ${basename(remotePath)} on remote...`);
	const result = sshCommand([`${hashType}sum`, remotePath]);

	if (!result.success || result.stdout.length === 0) {
		throw new Error(`Failed to calculate ${hashType} for ${remotePath} on remote`);
	}

	// Parse hash from output: "<hash>  /path/to/file"
	const hash = result.stdout.split(/\s/)[0];
	if (!hash || hash.length < 32) {
		throw new Error(`Invalid ${hashType} hash for ${remotePath} on remote`);
	}

	// Store the hash file on remote via SCP for future runs
	const hashContent = `${hash}  ${basename(remotePath)}\n`;
	const tmpFile = join(tmpdir(), `hash-${Date.now()}-${hashType}`);
	writeFileSync(tmpFile, hashContent);
	try {
		const uploaded = scpUpload(tmpFile, `${remotePath}.${hashType}`);
		if (!uploaded) {
			throw new Error(`Failed to upload ${hashType} hash to remote for ${basename(remotePath)}`);
		}
	} finally {
		unlinkSync(tmpFile);
	}

	return hash;
}

/**
 * Downloads and caches hashes for all files from remote storage.
 * Uses existing .md5 and .sha256 files on the remote, or calculates if missing.
 */
export async function generateHashes(files: FileRef[]) {
	// Clear hash cache contents to avoid stale entries from previous runs
	if (existsSync(DOWNLOAD_HASH_CACHE_DIR)) {
		for (const entry of readdirSync(DOWNLOAD_HASH_CACHE_DIR)) {
			rmSync(join(DOWNLOAD_HASH_CACHE_DIR, entry), { recursive: true });
		}
	} else {
		mkdirSync(DOWNLOAD_HASH_CACHE_DIR, { recursive: true });
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
			console.log(
				` - ${hashType} for ${basename(file.remotePath)}: ${hash ? 'downloaded' : 'not found, calculating...'}`,
			);
			if (hash) {
				downloaded++;
			} else {
				hash = calculateHashRemote(file.remotePath, hashType);
				calculated++;
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
