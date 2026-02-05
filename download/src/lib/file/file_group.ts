import { basename } from 'path';
import { FileRef } from './file_ref.js';
import { FileResponse } from './file_response.js';

/**
 * Represents a logical group of related files (typically different versions of
 * the same dataset) in the download.versatiles.org catalog.
 *
 * A group is identified by its `slug` (derived from the file name) and may
 * contain multiple `FileRef` instances:
 *
 * - `latestFile`: the most recent file that should be advertised and used by default
 * - `olderFiles`: additional versions that remain available for download
 *
 * The high-level workflow is:
 * - `groupFiles()` discovers all `FileRef`s and assigns them to `FileGroup`s
 *   based on the slug (usually the basename without extension).
 * - For each group, `latestFile` is determined from the file names and may
 *   have its `url` normalised (e.g. date suffix removed).
 * - The remaining entries are kept in `olderFiles` and exposed as "previous versions".
 *
 * The `local` flag indicates whether the latest file of this group should be
 * mirrored to a local volume for fast download.
 */
export class FileGroup {
	/** Machine-readable identifier of the group (derived from the file basename). */
	slug: string;

	/** Human-readable title shown in the download listing. */
	title: string;

	/** HTML-formatted description, including attribution and licence information. */
	desc: string;

	/**
	 * Sort order of the group in the UI.
	 * Lower values appear first in the listing.
	 */
	order: number;

	/**
	 * Whether the latest file of this group should be mirrored to a local volume
	 * (used for hosting "local" copies with better performance).
	 */
	local: boolean;

	/**
	 * The current default file for this group.
	 * Set by `groupFiles()` based on the most recent file name.
	 */
	latestFile?: FileRef;

	/**
	 * All available versions for this group, sorted from newest to oldest.
	 * The first entry is cloned and promoted to `latestFile` during grouping.
	 */
	olderFiles: FileRef[];
	constructor(options: { slug: string, title: string, desc: string, order: number, local?: boolean, latestFile?: FileRef, olderFiles?: FileRef[] }) {
		this.slug = options.slug;
		this.title = options.title;
		this.desc = options.desc;
		this.order = options.order;
		this.local = options.local ?? false;
		this.latestFile = options.latestFile;
		this.olderFiles = options.olderFiles ?? [];
	}
	/**
	 * Builds a `FileResponse` representing a TSV url list for the latest file
	 * in this group. The format follows the "TsvHttpData-1.0" specification:
	 *
	 *   TsvHttpData-1.0
	 *   <url>\t<size>\t<base64url(md5)>\n
	 *
	 * The `baseURL` parameter is used to turn the file's relative `url` into
	 * an absolute URL.
	 *
	 * Throws if no `latestFile` has been assigned to this group.
	 */
	getResponseUrlList(baseURL: string): FileResponse {
		const file = this.latestFile;
		if (file == null) throw Error(`no latest file found in group "${this.slug}"`)
		const url = new URL(file.url, baseURL).href;

		return new FileResponse(
			`/urllist_${this.slug}.tsv`,
			`TsvHttpData-1.0\n${url}\t${file.size}\t${hex2base64(file.md5)}\n`,
		);
	}
	/**
	 * Returns all virtual responses associated with this group:
	 *
	 * - `.md5` and `.sha256` checksum files for all versions
	 * - a TSV url list (`/urllist_<slug>.tsv`) for the latest version
	 */
	getResponses(baseURL: string): FileResponse[] {
		const result: FileResponse[] = this.olderFiles.flatMap(f => [
			f.getResponseMd5File(),
			f.getResponseSha256File(),
		]);
		if (this.latestFile) {
			result.push(
				this.latestFile.getResponseMd5File(),
				this.latestFile.getResponseSha256File(),
				this.getResponseUrlList(baseURL),
			);
		}
		return result;
	}
}

/**
 * Groups a flat list of `FileRef`s into logical `FileGroup`s.
 *
 * - The group `slug` is derived from `basename(file.filename)` without extension.
 * - Known slugs (`osm`, `hillshade-vectors`, `landcover-vectors`,
 *   `bathymetry-vectors`, `satellite`) get predefined titles, descriptions,
 *   ordering and the `local` flag.
 * - Unknown slugs are logged to stderr and still added with placeholder values.
 *
 * Within each group:
 * - Files are sorted by `filename` descending (newest first).
 * - The first entry is cloned into `latestFile`.
 * - If the filename contains a date in the form `.YYYYMMDD.`, it is removed
 *   from the `latestFile.url` to provide a stable, version-agnostic URL.
 *   Otherwise, the original URL is kept and the file is removed from
 *   `olderFiles` (so it only appears as `latestFile`).
 *
 * The resulting list is sorted by `order` for display.
 */
export function groupFiles(files: FileRef[]): FileGroup[] {
	const groupMap = new Map<string, FileGroup>();
	files.forEach(file => {
		const slug = basename(file.filename).replace(/\..*/, '');
		let group = groupMap.get(slug);

		if (!group) {
			let title = '???', desc: string[] = [], order = 10000, local = false;
			switch (slug) {
				case 'osm':
					title = 'OpenStreetMap as vector tiles';
					desc = [
						'The full <a href="https://www.openstreetmap.org/">OpenStreetMap</a> planet as vector tilesets with zoom levels 0-14 in <a href="https://shortbread-tiles.org/schema/">Shortbread Schema</a>.',
						'Map Data © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap Contributors</a> available under <a href="https://opendatacommons.org/licenses/odbl/">ODbL</a>'
					];
					order = 0;
					local = true;
					break;
				case 'hillshade-vectors':
					title = 'Hillshading as vector tiles';
					desc = [
						'Hillshade vector tiles based on <a href="https://github.com/tilezen/joerd">Mapzen Jörð Terrain Tiles</a>.',
						'Map Data © <a href="https://github.com/tilezen/joerd/blob/master/docs/attribution.md">Mapzen Terrain Tiles, DEM Sources</a>'
					]
					order = 10;
					break;
				case 'landcover-vectors':
					title = 'Landcover as vector tiles';
					desc = [
						'Landcover vector tiles based on <a href="https://esa-worldcover.org/en/data-access">ESA Worldcover 2021</a>.',
						'Map Data © <a href="https://esa-worldcover.org/en/data-access">ESA WorldCover project 2021</a> / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium, available under <a href="http://creativecommons.org/licenses/by/4.0/"> CC-BY 4.0 International</a>'
					]
					order = 20;
					break;
				case 'bathymetry-vectors':
					title = 'Bathymetry as vector tiles';
					desc = [
						'Bathymetry Vectors, derived from the <a href="https://www.gebco.net/data_and_products/historical_data_sets/#gebco_2021">GEBCO 2021 Grid</a>, made with <a href="https://www.naturalearthdata.com/">NaturalEarth</a> by <a href="https://opendem.info">OpenDEM</a>',
					];
					order = 30;
					break;
				case 'satellite':
					title = 'Satellite imagery (Beta)';
					desc = [
						'Satellite imagery from various sources.'
					];
					order = 40;
					break;
				default:
					console.error(`Unknown group "${slug}"`);
			}

			group = new FileGroup({ slug, title, desc: desc.join('<br>'), order, local });
			groupMap.set(slug, group);
		}

		group.olderFiles.push(file);
	});

	const groupList = Array.from(groupMap.values());

	groupList.sort((a, b) => a.order - b.order);

	groupList.forEach(group => {
		group.olderFiles.sort((a, b) => a.filename < b.filename ? 1 : -1);
		group.latestFile = group.olderFiles[0].clone();
		const newUrl = group.latestFile.url.replace(/\.\d{8}\./, '.');
		if (newUrl === group.latestFile.url) {
			group.olderFiles.shift();
		} else {
			group.latestFile.url = newUrl;
		}
	});

	return groupList;
}

/**
 * Collects all `FileRef`s from one or more `FileGroup` / `FileRef` inputs,
 * flattening nested arrays and deduplicating by `url`.
 *
 * This is used to build the final list of files that should be exposed by
 * nginx (e.g. all data files plus generated HTML / RSS).
 */
export function collectFiles(...entries: (FileGroup | FileGroup[] | FileRef | FileRef[])[]): FileRef[] {
	const files = new Map<string, FileRef>();
	for (const entry of entries) addEntry(entry);
	return Array.from(files.values());

	function addEntry(entry: FileGroup | FileGroup[] | FileRef | FileRef[]) {
		if (Array.isArray(entry)) {
			entry.forEach(addEntry);
		} else if (entry instanceof FileGroup) {
			addEntry(entry.olderFiles);
			if (entry.latestFile) addEntry(entry.latestFile);
		} else if (entry instanceof FileRef) {
			files.set(entry.url, entry);
		} else {
			throw new Error('Unsupported entry type in collectFiles; expected FileGroup, FileRef or arrays of those.');
		}
	}
}


/**
 * Converts a hexadecimal hash string into a base64url-encoded string
 * with proper padding.
 *
 * This is used for integrity fields where base64url encoding is required.
 */
export function hex2base64(hex: string): string {
	const base64 = Buffer.from(hex, 'hex').toString('base64url');
	return base64 + '='.repeat((4 - (base64.length % 4)) % 4);
}
