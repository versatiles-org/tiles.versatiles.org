/**
 * Data loading utilities for SvelteKit routes.
 *
 * Reads the pre-generated `data/fileGroups.json` file that the pipeline
 * writes before running `vite build`. The data structures are plain-object
 * versions of the `FileGroup` and `FileRef` classes used by the pipeline.
 */
import { readFileSync } from 'fs';
import { resolve } from 'path';

/** Plain-object version of FileRef (as serialised to JSON). */
export interface FileRefData {
	fullname: string;
	filename: string;
	url: string;
	size: number;
	sizeString: string;
	isRemote: boolean;
	remotePath: string;
	webdavPath: string;
	hashes?: { md5: string; sha256: string };
}

/** Plain-object version of FileGroup (as serialised to JSON). */
export interface FileGroupData {
	slug: string;
	title: string;
	desc: string;
	order: number;
	local: boolean;
	latestFile?: FileRefData;
	olderFiles: FileRefData[];
}

/**
 * Loads the file groups from the JSON data file written by the pipeline.
 * The file is located at `data/fileGroups.json` relative to the project root.
 */
export function loadFileGroups(): FileGroupData[] {
	const dataPath = resolve('data/fileGroups.json');
	return JSON.parse(readFileSync(dataPath, 'utf-8')) as FileGroupData[];
}
