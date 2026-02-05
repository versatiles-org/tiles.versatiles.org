
/**
 * Hash generation utilities for `.versatiles` files.
 *
 * This module is responsible for ensuring that each file in the remote storage
 * has associated `.md5` and `.sha256` checksum files. Missing hashes are computed
 * over SSH on the remote host and written locally next to the file.
 *
 * Workflow:
 * - For every `FileRef`, check whether `<file>.md5` and `<file>.sha256` exist.
 * - For each missing hash, execute `{md5,sha256}sum` remotely via SSH.
 * - Store the resulting checksum string in the corresponding sidecar file.
 * - Finally, read all checksum files and assign the values to `file.hashes`.
 *
 * Requirements:
 * - The remote server must expose a shell with the hashing utilities installed.
 * - Environment variable `STORAGE_URL` must contain the SSH user@host.
 * - SSH identity `.ssh/storage` must exist in the container environment.
 *
 * All hash values loaded here become available through `FileRef.md5` and
 * `FileRef.sha256`.
 */

import { existsSync, readFileSync, writeFileSync } from 'fs';
import { relative, resolve } from 'path';
import { FileRef } from './file_ref.js';
import { ProgressBar } from 'work-faster';
import { spawnSync } from 'child_process';

/**
 * Ensures that all provided files have MD5 and SHA256 checksum sidecar files.
 *
 * For each file:
 * - If `<file>.md5` or `<file>.sha256` is missing, compute it remotely via SSH.
 * - The remote command is executed in the directory that mirrors the
 *   structure of `remoteFolder`.
 * - Progress is measured in bytes processed (sum of file sizes).
 *
 * After all missing hashes are written, every file in `files` receives a
 * populated `file.hashes = { md5, sha256 }`.
 *
 * Throws:
 * - If SSH returns anything on stderr.
 * - If a checksum file cannot be read or has invalid format.
 */
export async function generateHashes(files: FileRef[], remoteFolder: string) {
	/** List of all (file, hashName) tasks that must be computed remotely. */
	const todos: { file: FileRef, hashName: string }[] = [];

	console.log('Check hashes...');
	files.forEach(file => {
		const fullnameMD5 = file.fullname + '.md5';
		if (!existsSync(fullnameMD5)) todos.push({ file, hashName: 'md5' });

		const fullnameSHA = file.fullname + '.sha256';
		if (!existsSync(fullnameSHA)) todos.push({ file, hashName: 'sha256' });
	})

	/**
	 * Compute missing hashes remotely and write `<file>.<hashName>` sidecar files.
	 * The remote path is constructed by mapping the local file path into the
	 * remote storage root using `relative(remoteFolder, file.fullname)`.
	 */
	if (todos.length > 0) {
		console.log(' - Calculate hashes...');

		const sum = todos.reduce((s, t) => s + t.file.size, 0);
		const progress = new ProgressBar(sum);

		for (const todo of todos) {
			const { file, hashName } = todo;
			const path = resolve('/home/', relative(remoteFolder, todo.file.fullname));
			const args = [
				process.env['STORAGE_URL'] ?? 'STORAGE_URL is missing',
				'-p', '23',
				'-i', '/app/.ssh/storage',
				'-oBatchMode=yes',
				hashName + 'sum',
				path
			]
			const result = spawnSync('ssh', args);
			if (result.stderr.length > 0) throw Error(result.stderr.toString());
			const hashString = result.stdout.toString().replace(/\s.*\//, ' ');
			writeFileSync(file.fullname + '.' + hashName, hashString);
			progress.increment(file.size);
		}
	}

	console.log('Read hashes...');
	files.forEach(f => {
		f.hashes = {
			md5: read('md5'),
			sha256: read('sha256'),
		};
		/**
		 * Reads a checksum file and strips everything after the first whitespace.
		 * The checksum utilities typically output `<hash>  <filename>`.
		 */
		function read(hash: string): string {
			return readFileSync(f.fullname + '.' + hash, 'utf8').replace(/\s.*/ms, '')
		}
	})
}
