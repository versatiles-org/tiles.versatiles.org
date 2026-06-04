/**
 * Synchronises the local `.versatiles` mirror with the CDN.
 *
 * The set of datasets is fixed (`DATASETS`); for each one the CDN serves a
 * stable object key `<slug>.versatiles` plus a `<slug>.versatiles.md5` sidecar.
 * A dataset is "current" when the local file exists and its stored MD5 matches
 * the CDN's. Stale or missing datasets are (re)downloaded with aria2c (parallel
 * connections, inline MD5 verification).
 */
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'fs';
import { resolve } from 'path';
import { DATASETS } from './datasets.js';
import { cdnBaseUrl, downloadWithAria2c, fetchText, parseHash } from './cdn.js';

export interface DatasetState {
	/** Dataset slug, e.g. `osm`. */
	slug: string;
	/** File name on the CDN and on local disk, `<slug>.versatiles`. */
	filename: string;
	/** HTTP path under which the file is exposed, `/<slug>.versatiles`. */
	url: string;
	/** MD5 reported by the CDN sidecar. */
	md5: string;
	/** Whether the file still needs fetching (true) or is current locally (false). */
	isRemote: boolean;
}

/** Reads the stored MD5 for a local file, or null if absent/invalid. */
function readLocalMd5(folder: string, filename: string): string | null {
	const path = resolve(folder, `${filename}.md5`);
	if (!existsSync(path)) return null;
	const hash = readFileSync(path, 'utf8').split(/\s/)[0];
	return hash && hash.length >= 32 ? hash : null;
}

/** Writes the MD5 sidecar for a local file. */
function writeLocalMd5(folder: string, filename: string, hash: string): void {
	writeFileSync(resolve(folder, `${filename}.md5`), `${hash}  ${filename}\n`);
}

/**
 * Fetches the current MD5 of every dataset from the CDN and returns their
 * initial state (all `isRemote = true` until checked or downloaded).
 */
export async function resolveDatasets(): Promise<DatasetState[]> {
	const cdn = cdnBaseUrl();
	console.log(`Resolving ${DATASETS.length} datasets from ${cdn}...`);
	return Promise.all(
		DATASETS.map(async (slug) => {
			const filename = `${slug}.versatiles`;
			const url = `/${filename}`;
			const md5 = parseHash(await fetchText(`${cdn}${url}.md5`));
			return { slug, filename, url, md5, isRemote: true };
		}),
	);
}

/**
 * Marks each dataset current (`isRemote = false`) when the local file exists
 * with a matching MD5, otherwise stale (`isRemote = true`). Downloads nothing.
 * Returns `true` if any dataset needs updating.
 */
export function checkLocalFiles(states: DatasetState[], tilesFolder: string): boolean {
	if (!existsSync(tilesFolder)) mkdirSync(tilesFolder, { recursive: true });

	let needsUpdate = false;
	for (const state of states) {
		const localPath = resolve(tilesFolder, state.filename);
		const localMd5 = readLocalMd5(tilesFolder, state.filename);
		if (existsSync(localPath) && localMd5 === state.md5) {
			state.isRemote = false;
		} else {
			state.isRemote = true;
			needsUpdate = true;
		}
	}
	return needsUpdate;
}

/**
 * Downloads stale/missing datasets from the CDN into `tilesFolder` and removes
 * any `.versatiles` files that are no longer part of `DATASETS`. Afterwards all
 * datasets are present locally (`isRemote = false`).
 */
export async function downloadLocalFiles(states: DatasetState[], tilesFolder: string): Promise<void> {
	if (!existsSync(tilesFolder)) mkdirSync(tilesFolder, { recursive: true });

	console.log('Syncing local files...');
	cleanupTempFiles(tilesFolder);
	deleteUnknownFiles(states, tilesFolder);

	const cdn = cdnBaseUrl();
	for (const state of states) {
		const localPath = resolve(tilesFolder, state.filename);
		const localMd5 = readLocalMd5(tilesFolder, state.filename);

		if (existsSync(localPath) && localMd5 === state.md5) {
			console.log(` - Keeping ${state.filename} (already up to date)`);
			state.isRemote = false;
			continue;
		}

		const url = `${cdn}${state.url}`;
		console.log(` - Downloading ${state.filename} from ${url} ...`);
		downloadWithAria2c(url, localPath, state.md5);
		writeLocalMd5(tilesFolder, state.filename, state.md5);
		state.isRemote = false;
	}
}

/** Removes leftover aria2c temp/control files from interrupted downloads. */
function cleanupTempFiles(folder: string): void {
	for (const entry of readdirSync(folder)) {
		if (entry.includes('.download') || entry.endsWith('.aria2')) {
			console.log(` - Cleaning up temp file: ${entry}`);
			rmSync(resolve(folder, entry));
		}
	}
}

/** Deletes `.versatiles` files (and their `.md5`) that are not in `DATASETS`. */
function deleteUnknownFiles(states: DatasetState[], folder: string): void {
	const wanted = new Set(states.map((state) => state.filename));
	for (const entry of readdirSync(folder)) {
		if (entry.endsWith('.versatiles') && !wanted.has(entry)) {
			console.log(` - Deleting ${entry}`);
			rmSync(resolve(folder, entry));
			const md5Path = resolve(folder, `${entry}.md5`);
			if (existsSync(md5Path)) rmSync(md5Path);
		}
	}
}
