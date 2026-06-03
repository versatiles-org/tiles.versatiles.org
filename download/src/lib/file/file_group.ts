import { basename } from 'path';
import { FileRef } from './file_ref.js';

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
	 * The type of tiles contained in this group's files.
	 * - `'vector'`: Protocol Buffer encoded vector tiles (e.g. MVT/PBF)
	 * - `'raster'`: Image-based raster tiles (e.g. PNG, JPEG, WebP)
	 */
	tileType: 'raster' | 'vector';

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
	constructor(options: {
		slug: string;
		title: string;
		desc: string;
		order: number;
		local?: boolean;
		tileType?: 'raster' | 'vector';
		latestFile?: FileRef;
		olderFiles?: FileRef[];
	}) {
		this.slug = options.slug;
		this.title = options.title;
		this.desc = options.desc;
		this.order = options.order;
		this.local = options.local ?? false;
		this.tileType = options.tileType ?? 'vector';
		this.latestFile = options.latestFile;
		this.olderFiles = options.olderFiles ?? [];
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
	files.forEach((file) => {
		const slug = basename(file.filename).replace(/\..*/, '');
		let group = groupMap.get(slug);

		if (!group) {
			let title = '???',
				desc: string[] = [],
				order = 10000,
				local = false,
				tileType: 'raster' | 'vector' = 'vector';
			switch (slug) {
				case 'osm':
					title = 'OpenStreetMap';
					desc = [
						'Full planet tileset with zoom levels 0-14 in <a href="https://shortbread-tiles.org/schema/">Shortbread Schema</a>.',
						'© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap Contributors</a>, available under <a href="https://opendatacommons.org/licenses/odbl/">ODbL</a>',
					];
					order = 0;
					local = true;
					break;
				case 'satellite':
					title = 'Satellite Imagery (Beta)';
					desc = [
						'Global satellite imagery composited from <a href="https://versatiles.org/sources/">open data sources</a>.',
					];
					order = 10;
					local = true;
					tileType = 'raster';
					break;
				case 'elevation':
					title = 'Elevation Data (Beta)';
					desc = [
						'Global elevation data encoded as raster tiles.',
						'© <a href=\"https://mapterhorn.com/attribution\">Mapterhorn</a>',
					];
					order = 20;
					local = true;
					tileType = 'raster';
					break;
				case 'landcover-vectors':
					title = 'Landcover';
					desc = [
						'Global landcover classification based on <a href="https://esa-worldcover.org/en/data-access">ESA WorldCover 2021</a>.',
						'© <a href="https://esa-worldcover.org/en/data-access">ESA WorldCover project 2021</a> / Contains modified Copernicus Sentinel data (2021), available under <a href="http://creativecommons.org/licenses/by/4.0/">CC-BY 4.0</a>',
					];
					order = 30;
					local = true;
					break;
				case 'hillshade-vectors':
					title = 'Hillshading';
					desc = [
						'Hillshade contours based on <a href="https://github.com/tilezen/joerd">Mapzen Terrain Tiles</a>.',
						'© <a href="https://github.com/tilezen/joerd/blob/master/docs/attribution.md">Mapzen Terrain Tiles, DEM Sources</a>',
					];
					order = 40;
					local = true;
					break;
				case 'bathymetry-vectors':
					title = 'Bathymetry';
					desc = [
						'Ocean depth contours derived from the <a href="https://www.gebco.net/data_and_products/historical_data_sets/#gebco_2021">GEBCO 2021 Grid</a>, processed with <a href="https://www.naturalearthdata.com/">Natural Earth</a> by <a href="https://opendem.info">OpenDEM</a>.',
					];
					order = 50;
					local = true;
					break;
				default:
					console.error(`Unknown group "${slug}"`);
			}

			group = new FileGroup({ slug, title, desc: desc.join('<br>'), order, local, tileType });
			groupMap.set(slug, group);
		}

		group.olderFiles.push(file);
	});

	const groupList = Array.from(groupMap.values());

	groupList.sort((a, b) => a.order - b.order);

	groupList.forEach((group) => {
		group.olderFiles.sort((a, b) => (a.filename < b.filename ? 1 : -1));
		group.latestFile = group.olderFiles[0].clone();
		const newUrl = group.latestFile.url.replace(/\.\d{8}\./, '.');
		if (newUrl === group.latestFile.url) {
			group.olderFiles.shift();
		} else {
			group.latestFile.url = newUrl;
			group.latestFile.filename = newUrl.replace(/^\/+/, '');
		}
	});

	return groupList;
}
