/**
 * Generates sample `data/fileGroups.json` for local development.
 * Data mirrors the production site at https://download.versatiles.org/.
 *
 * Usage: npx tsx src/generate_testdata.ts
 */
import { mkdirSync, writeFileSync } from 'fs';
import { resolve } from 'path';
import { FileRef } from './lib/file/file_ref.js';
import { groupFiles } from './lib/file/file_group.js';

// Build FileRef instances matching the production download.versatiles.org data.
// OSM has dated versions; the other groups have single non-dated files.
const fakeFiles: FileRef[] = [
	// OSM — 9 dated versions (newest first becomes latestFile with date stripped)
	makeRef('osm.20260105.versatiles', 58.1),
	makeRef('osm.20251006.versatiles', 59.6),
	makeRef('osm.20250728.versatiles', 56.2),
	makeRef('osm.20250407.versatiles', 55.1),
	makeRef('osm.20250106.versatiles', 53.8),
	makeRef('osm.20241007.versatiles', 55.6),
	makeRef('osm.20240701.versatiles', 54.8),
	makeRef('osm.20240325.versatiles', 53.7),
	makeRef('osm.20240101.versatiles', 51.8),

	// Hillshade — single non-dated file
	makeRef('hillshade-vectors.versatiles', 105.4),

	// Landcover — single non-dated file
	makeRef('landcover-vectors.versatiles', 0.8),

	// Bathymetry — single non-dated file
	makeRef('bathymetry-vectors.versatiles', 0.7),

	// Satellite — single non-dated file
	makeRef('satellite.versatiles', 723.3),
];

// Assign dummy hashes so serialisation includes them
for (const f of fakeFiles) {
	f.hashes = {
		md5: 'a'.repeat(32),
		sha256: 'b'.repeat(64),
	};
}

const fileGroups = groupFiles(fakeFiles);

const dataDir = resolve('data');
mkdirSync(dataDir, { recursive: true });
writeFileSync(resolve(dataDir, 'fileGroups.json'), JSON.stringify(fileGroups, null, '\t'));
console.log(`Wrote data/fileGroups.json with ${fileGroups.length} groups`);

function makeRef(filename: string, sizeGB: number): FileRef {
	const remotePath = `/home/data/${filename}`;
	const size = Math.round(sizeGB * 2 ** 30);
	const ref = new FileRef(remotePath, size, remotePath);
	ref.filename = filename;
	ref.url = '/' + filename;
	return ref;
}
