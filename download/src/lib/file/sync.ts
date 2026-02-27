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
 * - When a file with identical size already exists locally, it is reused.
 */
import { readdirSync, rmSync, statSync, existsSync, mkdirSync, renameSync } from 'fs';
import { spawnSync } from 'child_process';
import { basename, resolve } from 'path';
import { FileRef } from './file_ref.js';
import { FileGroup } from './file_group.js';

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

	const args = [
		'-i', '/app/.ssh/storage',
		'-P', '23',
		'-o', 'BatchMode=yes',
		'-o', 'StrictHostKeyChecking=accept-new',
		`${storageUrl}:${remotePath}`,
		tempPath
	];

	console.log(` - Downloading ${basename(remotePath)}...`);
	const result = spawnSync('scp', args, { stdio: 'inherit', timeout: 3600000 });

	if (result.status !== 0) {
		try { rmSync(tempPath); } catch { /* ignore cleanup errors */ }
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
	const wantedFiles = fileGroups.flatMap(group =>
		(group.local && group.latestFile) ? [group.latestFile] : []
	);

	const existingFiles = getLocalFiles(localFolder);

	syncFiles(wantedFiles, existingFiles, localFolder);
}

/**
 * Synchronises the `localFolder` to match the given list of `wantedFiles`.
 *
 * Behaviour:
 * - Any file present locally but *not* in `wantedFiles` is deleted.
 * - Any file in `wantedFiles` that is missing or size-mismatched locally is downloaded.
 * - If a matching local file exists with identical size, it is reused.
 */
export function syncFiles(wantedFiles: FileRef[], existingFiles: FileRef[], localFolder: string) {
	console.log('Syncing local files...');

	// Ensure local folder exists
	if (!existsSync(localFolder)) {
		mkdirSync(localFolder, { recursive: true });
	}

	/** Map of existing local files by filename */
	const existingMap = new Map(existingFiles.map(f => [f.filename, f]));
	/** Map of wanted files by filename */
	const wantedMap = new Map(wantedFiles.map(f => [f.filename, f]));

	// Delete files that are no longer wanted
	for (const [filename, existingFile] of existingMap) {
		const wantedFile = wantedMap.get(filename);
		if (!wantedFile || wantedFile.size !== existingFile.size) {
			console.log(` - Deleting ${filename}`);
			rmSync(existingFile.fullname);
		}
	}

	// Download missing files
	for (const [filename, wantedFile] of wantedMap) {
		const existingFile = existingMap.get(filename);
		const localPath = resolve(localFolder, filename);

		// Always verify file actually exists on disk before deciding to keep it
		const fileExistsOnDisk = existingFile && existsSync(localPath);

		if (fileExistsOnDisk && existingFile.size === wantedFile.size) {
			// File already exists with correct size, reuse it
			console.log(` - Keeping ${filename} (already up to date)`);
			wantedFile.fullname = localPath;
			wantedFile.isRemote = false;
		} else {
			// Need to download (file missing, size mismatch, or doesn't exist on disk)
			downloadViaSCP(wantedFile.remotePath, localPath);
			wantedFile.fullname = localPath;
			wantedFile.isRemote = false;
		}
	}
}
