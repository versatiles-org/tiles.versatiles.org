import { readdirSync, statSync } from 'fs';
import { basename, join, relative, resolve } from 'path';
import { FileResponse } from './file_response.js';

/**
 * Represents a single file that is part of the download.versatiles.org catalog.
 *
 * A `FileRef` has three perspectives on the same file:
 * - `fullname`: absolute path on the local filesystem
 * - `filename`: the basename or path relative to the "root" directory
 * - `url`: the path as it will be exposed via HTTP (typically relative to the web root)
 *
 * The class is intentionally lightweight and mostly behaves like a data container.
 * Construction is flexible to support the different call sites in the pipeline:
 *
 * - `new FileRef(fullname, url)`:
 *   Uses the given `fullname` and `url`, and determines the file size from the filesystem.
 * - `new FileRef(fullname, size)`:
 *   Uses the given `fullname` and a known `size` in bytes. The `url` defaults to `basename(fullname)`.
 * - `new FileRef(fileRef)`:
 *   Copy constructor that clones an existing instance.
 *
 * The `sizeString` is a human-readable representation of the file size in GiB
 * (rounded to one decimal place, e.g. `"1.5 GB"`).
 *
 * Hashes (`hashes.md5` / `hashes.sha256`) are optional and are typically populated
 * by the hash generation step. Accessing `md5` or `sha256` before they are set
 * will throw an error to surface misconfigurations early.
 */
export class FileRef {
	/** Absolute path of the file on disk. */
	public fullname: string;

	/**
	 * File name or path relative to a logical root directory.
	 * Typically used for display and for constructing URLs.
	 */
	public filename: string;

	/**
	 * Path under which the file is exposed via HTTP.
	 * This is usually relative to the web root (e.g. `"foo/bar.versatiles"`),
	 * but may also be an absolute path starting with `/`.
	 */
	public url: string;

	/** Raw file size in bytes. */
	public readonly size: number;

	/** Human-readable size string (e.g. `"1.2 GB"`). */
	public readonly sizeString: string;

	/** Optional precomputed hashes for integrity / checksum files. */
	public hashes?: { md5: string, sha256: string };

	constructor(fullname: string, url: string);
	constructor(fullname: string, size: number);
	constructor(file: FileRef);
	constructor(a: FileRef | string, b?: number | string) {
		if (typeof a === 'string') {
			this.fullname = a;
			this.filename = basename(a);
			if (typeof b === 'string') {
				this.url = b;
				this.size = statSync(a).size;
			} else if (typeof b === 'number') {
				this.url = '/' + this.filename;
				this.size = b;
			} else {
				throw new Error('Invalid FileRef constructor arguments: expected (fullname, url:string) or (fullname, size:number).');
			}
		} else if (a instanceof FileRef) {
			this.fullname = a.fullname;
			this.filename = a.filename;
			this.url = a.url;
			this.size = a.size;
			this.hashes = a.hashes;
		} else {
			throw new Error('Invalid FileRef constructor arguments: expected a string path or an existing FileRef instance.');
		}

		this.sizeString = (this.size / (2 ** 30)).toFixed(1) + ' GB';

		if (!/^\/[^/]/.test(this.url)) {
			throw new Error(`FileRef.url must start with a single '/', got: ${this.url}`);
		}
	}

	/**
	 * Returns the MD5 hash of the file.
	 *
	 * Throws if hashes have not been assigned yet. This usually means the
	 * hash generation step has not been executed or did not include this file.
	 */
	get md5(): string {
		if (!this.hashes) throw Error(`MD5 hash is missing for file "${this.filename}"`);
		return this.hashes.md5;
	}

	/**
	 * Returns the SHA256 hash of the file.
	 *
	 * Throws if hashes have not been assigned yet. This usually means the
	 * hash generation step has not been executed or did not include this file.
	 */
	get sha256(): string {
		if (!this.hashes) throw Error(`SHA256 hash is missing for file "${this.filename}"`);
		return this.hashes.sha256;
	}

	/**
	 * Builds a virtual `.md5` checksum file for this file.
	 * The content follows the standard `<hash> <filename>` format.
	 */
	getResponseMd5File(): FileResponse {
		return new FileResponse(`${this.url}.md5`, `${this.md5} ${basename(this.url)}\n`);
	}

	/**
	 * Builds a virtual `.sha256` checksum file for this file.
	 * The content follows the standard `<hash> <filename>` format.
	 */
	getResponseSha256File(): FileResponse {
		return new FileResponse(`${this.url}.sha256`, `${this.sha256} ${basename(this.url)}\n`);
	}

	/** Creates a shallow copy of this FileRef, including hashes if present. */
	clone(): FileRef {
		return new FileRef(this);
	}

	/**
	 * Creates a copy of this FileRef whose `fullname` has been moved from one
	 * root directory to another, preserving `filename`, `url`, and hashes.
	 *
	 * Only the filesystem path (`fullname`) is updated; the URL remains unchanged.
	 */
	cloneMoved(from: string, to: string): FileRef {
		const f = new FileRef(this);
		f.fullname = join(to, relative(from, f.fullname));
		return f;
	}
}

/**
 * Recursively scans a directory for `.versatiles` files and returns a sorted
 * list of `FileRef` instances.
 *
 * - `fullname` is the absolute path on disk.
 * - `filename` and `url` are set to the path relative to the initial `folderPath`.
 *
 * The returned list is sorted by `fullname` for stable processing.
 */
export function getAllFilesRecursive(folderPath: string): FileRef[] {
	return rec(folderPath).sort((a, b) => a.fullname.localeCompare(b.fullname));

	function rec(folderPath: string): FileRef[] {
		const files: FileRef[] = [];
		const filenames = readdirSync(folderPath);
		for (const filename of filenames) {
			const fullPath = resolve(folderPath, filename);
			if (statSync(fullPath).isDirectory()) {
				files.push(...rec(fullPath)); // Recursive call for subdirectory
			} else if (filename.endsWith('.versatiles')) {
				files.push(new FileRef(fullPath, '/' + filename));
			}
		}
		return files;
	}
}
