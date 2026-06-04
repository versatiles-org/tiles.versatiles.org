/**
 * The datasets this tile server mirrors and serves.
 *
 * Each entry is the slug used both as the stable object key on the CDN
 * (`<slug>.versatiles`, with a `<slug>.versatiles.md5` checksum sidecar) and as
 * the tile source `name` in the generated `versatiles.yaml`.
 *
 * The CDN exposes no listing, so this list is the authoritative set of datasets
 * to keep in sync — add or remove slugs here to change what is served.
 */
export const DATASETS: readonly string[] = [
	'osm',
	'satellite',
	'elevation',
	'landcover-vectors',
	'hillshade-vectors',
	'bathymetry-vectors',
];
