/**
 * Utilities for synchronising `.versatiles` files between remote storage
 * and the local high-speed download folder.
 *
 * The local folder contains only a subset of files — typically the latest
 * file from each `FileGroup` that has `local: true`. This module ensures that:
 *
 * - Files that should be present locally but are missing are downloaded via SSH.
 * - Files that are no longer needed (outdated or no longer marked `local`)
 *   are removed.
 * - When a file with a matching hash already exists locally, it is reused.
 */
import { readdirSync, readFileSync, rmSync, statSync, existsSync, mkdirSync, renameSync, writeFileSync } from 'fs';
import { spawnSync } from 'child_process';
import { basename, resolve } from 'path';
import { FileRef } from './file_ref.js';
import { FileGroup } from './file_group.js';

/** Shared SSH connection options (without port flag, since SSH uses -p and SCP uses -P) */
const SSH_COMMON_OPTIONS = ['-i', '/app/.ssh/storage', '-oBatchMode=yes', '-oStrictHostKeyChecking=accept-new'];

/**
 * Reads a local hash file and returns the hash string, or null if not found.
 */
function readLocalHash(localFolder: string, filename: string, hashType: string): string | null {
	const hashPath = resolve(localFolder, `${filename}.${hashType}`);
	if (!existsSync(hashPath)) return null;
	const content = readFileSync(hashPath, 'utf8');
	const hash = content.split(/\s/)[0];
	return hash && hash.length >= 32 ? hash : null;
}

/**
 * Writes a local hash file.
 */
function writeLocalHash(localFolder: string, filename: string, hashType: string, hash: string): void {
	const hashPath = resolve(localFolder, `${filename}.${hashType}`);
	writeFileSync(hashPath, `${hash}  ${filename}\n`);
}

/**
 * Scans a local directory for .versatiles files.
 */
function getLocalFiles(folderPath: string): FileRef[] {
	if (!existsSync(folderPath)) {
		mkdirSync(folderPath, { recursive: true });
		return [];
	}

	const files: FileRef[] = [];
	const filenames = readdirSync(folderPath);
	for (const filename of filenames) {
		if (!filename.endsWith('.versatiles')) continue;
		const fullPath = resolve(folderPath, filename);
		const stat = statSync(fullPath);
		if (stat.isFile()) {
			const file = new FileRef(fullPath, '/' + filename);
			files.push(file);
		}
	}
	return files;
}

/**
 * Downloads a file from remote storage via SCP.
 * Uses atomic download: writes to a temp file first, then renames on success.
 */
function downloadViaSCP(remotePath: string, localPath: string): void {
	const storageUrl = process.env['STORAGE_URL'];
	if (!storageUrl) throw new Error('STORAGE_URL not set');

	const tempPath = localPath + '.download.' + Date.now();

	const args = ['-P', '23', ...SSH_COMMON_OPTIONS, `${storageUrl}:${remotePath}`, tempPath];

	console.log(` - Downloading ${basename(remotePath)}...`);
	const result = spawnSync('scp', args, { stdio: 'inherit', timeout: 3600000 });

	if (result.status !== 0) {
		try {
			rmSync(tempPath);
		} catch {
			/* ignore cleanup errors */
		}
		throw new Error(`SCP failed for ${remotePath}`);
	}

	// Atomic rename
	renameSync(tempPath, localPath);
}

/**
 * Mirrors the "latest local" files of all `FileGroup`s into the local folder.
 *
 * For every group:
 * - If `group.local === true` and a `latestFile` exists, that file is included.
 * - All other files are ignored.
 */
export async function downloadLocalFiles(fileGroups: FileGroup[], localFolder: string) {
	const wantedFiles = fileGroups.flatMap((group) => (group.local && group.latestFile ? [group.latestFile] : []));

	const existingFiles = getLocalFiles(localFolder);

	syncFiles(wantedFiles, existingFiles, localFolder);
}

/**
 * Synchronises the `localFolder` to match the given list of `wantedFiles`.
 *
 * Behaviour:
 * - Any file present locally but *not* in `wantedFiles` is deleted.
 * - Any file in `wantedFiles` that is missing or hash-mismatched locally is downloaded.
 * - If a matching local file exists with an identical hash, it is reused.
 */
export function syncFiles(wantedFiles: FileRef[], existingFiles: FileRef[], localFolder: string) {
	console.log('Syncing local files...');

	// Ensure local folder exists
	if (!existsSync(localFolder)) {
		mkdirSync(localFolder, { recursive: true });
	}

	// Clean up orphaned temp files from interrupted downloads
	const orphans = readdirSync(localFolder).filter((f) => f.includes('.download.'));
	for (const orphan of orphans) {
		console.log(` - Cleaning up orphaned temp file: ${orphan}`);
		rmSync(resolve(localFolder, orphan));
	}

	/** Map of existing local files by filename */
	const existingMap = new Map(existingFiles.map((f) => [f.filename, f]));
	/** Map of wanted files by filename */
	const wantedMap = new Map(wantedFiles.map((f) => [f.filename, f]));

	// Delete files that are no longer wanted
	for (const [filename, existingFile] of existingMap) {
		const wantedFile = wantedMap.get(filename);
		if (!wantedFile) {
			console.log(` - Deleting ${filename}`);
			rmSync(existingFile.fullname);
			// Also delete associated hash files
			for (const hashType of ['md5', 'sha256']) {
				const hashPath = resolve(localFolder, `${filename}.${hashType}`);
				if (existsSync(hashPath)) rmSync(hashPath);
			}
		}
	}

	// Download missing or changed files
	for (const [filename, wantedFile] of wantedMap) {
		const existingFile = existingMap.get(filename);
		const localPath = resolve(localFolder, filename);

		// Always verify file actually exists on disk before deciding to keep it
		const fileExistsOnDisk = existingFile && existsSync(localPath);

		// Compare using hash instead of size
		const localHash = fileExistsOnDisk ? readLocalHash(localFolder, filename, 'md5') : null;
		const remoteHash = wantedFile.hashes?.md5 ?? null;

		if (fileExistsOnDisk && localHash && remoteHash && localHash === remoteHash) {
			// File already exists with correct hash, reuse it
			console.log(` - Keeping ${filename} (already up to date)`);
			wantedFile.fullname = localPath;
			wantedFile.isRemote = false;
		} else {
			// Need to download (file missing, hash mismatch, or doesn't exist on disk)
			downloadViaSCP(wantedFile.remotePath, localPath);
			wantedFile.fullname = localPath;
			wantedFile.isRemote = false;

			// Write local hash files for future comparisons
			if (wantedFile.hashes) {
				writeLocalHash(localFolder, filename, 'md5', wantedFile.hashes.md5);
				writeLocalHash(localFolder, filename, 'sha256', wantedFile.hashes.sha256);
			}
		}
	}
}
