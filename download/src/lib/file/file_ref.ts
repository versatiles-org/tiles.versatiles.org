import { execSync } from 'child_process';
import { basename, join, relative } from 'path';
import { statSync } from 'fs';
import { FileResponse } from './file_response.js';

/**
 * Represents a single file that is part of the download.versatiles.org catalog.
 *
 * A `FileRef` tracks:
 * - `fullname`: path for nginx (local files) or relative path for WebDAV (remote files)
 * - `filename`: the basename or path relative to the "root" directory
 * - `url`: the path as it will be exposed via HTTP
 * - `isRemote`: whether this file should be served via WebDAV proxy
 * - `remotePath`: the path on the remote storage (for WebDAV URL construction)
 */
export class FileRef {
	/** Path for nginx alias (local) or relative path on remote storage (remote). */
	public fullname: string;

	/** File name or path relative to a logical root directory. */
	public filename: string;

	/** Path under which the file is exposed via HTTP. */
	public url: string;

	/** Raw file size in bytes. */
	public readonly size: number;

	/** Human-readable size string (e.g. `"1.2 GB"`). */
	public readonly sizeString: string;

	/** Whether this file is served via WebDAV proxy (true) or local alias (false). */
	public isRemote: boolean;

	/** Full path on remote storage (e.g., /home/osm/file.versatiles). */
	public remotePath: string;

	/** Path for WebDAV URL (without /home prefix). */
	public webdavPath: string;

	/** Optional precomputed hashes for integrity / checksum files. */
	public hashes?: { md5: string, sha256: string };

	constructor(fullname: string, url: string);
	constructor(fullname: string, size: number);
	constructor(fullname: string, size: number, remotePath: string);
	constructor(file: FileRef);
	constructor(a: FileRef | string, b?: number | string, c?: string) {
		if (typeof a === 'string') {
			this.fullname = a;
			this.filename = basename(a);
			if (typeof b === 'string') {
				// (fullname, url) - local file, get size from filesystem
				this.url = b;
				this.size = statSync(a).size;
				this.isRemote = false;
				this.remotePath = '';
				this.webdavPath = '';
			} else if (typeof b === 'number' && typeof c === 'string') {
				// (fullname, size, remotePath) - remote file
				this.url = '/' + this.filename;
				this.size = b;
				this.isRemote = true;
				this.remotePath = c;
				this.webdavPath = c.replace(/^\/home/, '');
			} else if (typeof b === 'number') {
				// (fullname, size) - local file with known size
				this.url = '/' + this.filename;
				this.size = b;
				this.isRemote = false;
				this.remotePath = '';
				this.webdavPath = '';
			} else {
				throw new Error('Invalid FileRef constructor arguments.');
			}
		} else if (a instanceof FileRef) {
			this.fullname = a.fullname;
			this.filename = a.filename;
			this.url = a.url;
			this.size = a.size;
			this.isRemote = a.isRemote;
			this.remotePath = a.remotePath;
			this.webdavPath = a.webdavPath;
			this.hashes = a.hashes;
		} else {
			throw new Error('Invalid FileRef constructor arguments.');
		}

		this.sizeString = (this.size / (2 ** 30)).toFixed(1) + ' GB';

		if (!/^\/[^/]/.test(this.url)) {
			throw new Error(`FileRef.url must start with a single '/', got: ${this.url}`);
		}
	}

	/** Returns the MD5 hash of the file. Throws if not set. */
	get md5(): string {
		if (!this.hashes) throw Error(`MD5 hash is missing for file "${this.filename}"`);
		return this.hashes.md5;
	}

	/** Returns the SHA256 hash of the file. Throws if not set. */
	get sha256(): string {
		if (!this.hashes) throw Error(`SHA256 hash is missing for file "${this.filename}"`);
		return this.hashes.sha256;
	}

	/** Builds a virtual `.md5` checksum file for this file. */
	getResponseMd5File(): FileResponse {
		return new FileResponse(`${this.url}.md5`, `${this.md5} ${basename(this.url)}\n`);
	}

	/** Builds a virtual `.sha256` checksum file for this file. */
	getResponseSha256File(): FileResponse {
		return new FileResponse(`${this.url}.sha256`, `${this.sha256} ${basename(this.url)}\n`);
	}

	/** Creates a shallow copy of this FileRef. */
	clone(): FileRef {
		return new FileRef(this);
	}

	/**
	 * Creates a copy of this FileRef whose `fullname` has been moved from one
	 * root directory to another. Only applies to local files.
	 */
	cloneMoved(from: string, to: string): FileRef {
		const f = new FileRef(this);
		if (!f.isRemote) {
			f.fullname = join(to, relative(from, f.fullname));
		}
		return f;
	}
}

/**
 * Scans remote storage via SSH and returns a list of FileRef instances
 * for all .versatiles files found.
 *
 * Uses SSH to run `ls -lR` on the remote storage and parses the output.
 * Compatible with Hetzner storage box restricted shell.
 */
export function getRemoteFilesViaSSH(): FileRef[] {
	const storageUrl = process.env['STORAGE_URL'];
	if (!storageUrl) throw new Error('STORAGE_URL environment variable is not set');

	const sshKeyPath = '/app/.ssh/storage';

	console.log('Scanning remote storage via SSH...');

	// Use ls -lR for compatibility with restricted shells (Hetzner storage box)
	const cmd = `ssh -i ${sshKeyPath} -p 23 -o BatchMode=yes -o StrictHostKeyChecking=accept-new ${storageUrl} "ls -lR /home"`;

	let output: string;
	try {
		output = execSync(cmd, { encoding: 'utf-8', timeout: 120000, stdio: ['pipe', 'pipe', 'pipe'] });
	} catch (error) {
		throw new Error(`Failed to scan remote storage via SSH: ${error}`);
	}

	const files: FileRef[] = [];
	const lines = output.trim().split('\n');

	let currentDir = '/home';

	for (const line of lines) {
		// Directory header: "/home/dirname:" or just directory listing
		if (line.endsWith(':')) {
			currentDir = line.slice(0, -1);
			continue;
		}

		// Skip empty lines and total lines
		if (!line.trim() || line.startsWith('total ')) continue;

		// Skip directory entries (start with 'd')
		if (line.startsWith('d')) continue;

		// Parse ls -l output: -rw-r--r-- 1 user group SIZE month day time/year filename
		const parts = line.trim().split(/\s+/);
		if (parts.length < 9) continue;

		const size = parseInt(parts[4], 10);
		if (isNaN(size)) continue;

		// Filename is everything from field 8 onwards (in case filename has spaces)
		const filename = parts.slice(8).join(' ');
		if (!filename.endsWith('.versatiles')) continue;

		const remotePath = `${currentDir}/${filename}`;

		// Create FileRef with remote path info
		const file = new FileRef(remotePath, size, remotePath);
		file.filename = filename;
		file.url = '/' + filename;

		files.push(file);
	}

	console.log(` - Found ${files.length} .versatiles files`);
	return files.sort((a, b) => a.fullname.localeCompare(b.fullname));
}
