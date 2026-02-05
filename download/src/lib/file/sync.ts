/**
 * Utilities for synchronising `.versatiles` files between the remote storage
 * folder and the local high-speed download folder.
 *
 * The `local` folder contains only a subset of files — typically the latest
 * file from each `FileGroup` that has `local: true`. This module ensures that:
 *
 * - Files that should be present locally but are missing are copied in.
 * - Files that are no longer needed (outdated or no longer marked `local`)
 *   are removed.
 * - When a file with identical size already exists locally, the existing
 *   file is reused and the `FileRef.fullname` is updated accordingly.
 *
 * All operations here are synchronous (copy/delete) and intentionally simple,
 * because they run inside a container with predictable I/O behaviour.
 */
import { cpSync, rmSync } from 'fs';
import { FileRef, getAllFilesRecursive } from './file_ref.js';
import { resolve } from 'path';
import { FileGroup } from './file_group.js';


/**
 * Mirrors the "latest local" files of all `FileGroup`s into the local folder.
 *
 * For every group:
 * - If `group.local === true` and a `latestFile` exists, that file is included.
 * - All other files are ignored.
 *
 * Delegates the actual copy/delete logic to `syncFiles()`.
 */
export async function downloadLocalFiles(fileGroups: FileGroup[], localFolder: string) {
	const localFiles = fileGroups.flatMap(group =>
		(group.local && group.latestFile) ? [group.latestFile] : []
	);
	syncFiles(localFiles, getAllFilesRecursive(localFolder), localFolder);
}

/**
 * Synchronises the `localFolder` to match the given list of `remoteFiles`.
 *
 * Behaviour:
 * - Any file present locally but *not* in `remoteFiles` is deleted.
 * - Any file in `remoteFiles` that is missing or size-mismatched locally is copied in.
 * - If a matching local file exists with identical size, it is reused and
 *   the corresponding `remoteFile.fullname` is updated to point to the local copy.
 *
 * Notes:
 * - Files are matched by `filename` only — not by hash — because this is a
 *   lightweight mirroring step executed after hash verification already occurred.
 * - After copying, `remoteFile.fullname` is overwritten to reflect the new
 *   on-disk location in the local folder.
 */
export function syncFiles(remoteFiles: FileRef[], localFiles: FileRef[], localFolder: string) {
	console.log('Syncing files...');

	/** Clone local files into a mutable map so we can remove retained entries. */
	const deleteFiles = new Map(localFiles.map(f => [f.filename, f]));
	/** Clone remote files into a mutable map; items removed from this set will not be copied. */
	const copyFiles = new Map(remoteFiles.map(f => [f.filename, f]));

	/**
	 * Detect matching local files (same filename + identical size) and mark them
	 * as retained. Reuses the local file path by updating `remoteFile.fullname`.
	 */
	for (const remoteFile of remoteFiles) {
		const { filename } = remoteFile;
		const localFile = deleteFiles.get(filename);
		if (localFile && localFile.size === remoteFile.size) {
			copyFiles.delete(filename);
			deleteFiles.delete(filename);
			remoteFile.fullname = localFile.fullname;
		}
	}

	/** Delete all local files that were not matched to any remote file. */
	for (const file of deleteFiles.values()) {
		console.log(` - Deleting "${file.filename}"`);
		rmSync(file.fullname);
	}

	/**
	 * Copy in any remote files that were not matched locally.
	 * After copying, update `file.fullname` to its new location.
	 */
	for (const file of copyFiles.values()) {
		const fullname = resolve(localFolder, file.filename);
		console.log(` - Copying "${file.filename}"`);
		cpSync(file.fullname, fullname);
		file.fullname = fullname; // Update the file's fullname to reflect its new location
	}
}
