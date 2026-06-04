import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('fs', () => ({
	existsSync: vi.fn(),
	mkdirSync: vi.fn(),
	readFileSync: vi.fn(),
	readdirSync: vi.fn(),
	rmSync: vi.fn(),
	writeFileSync: vi.fn(),
}));

import { checkLocalFiles, type DatasetState } from './sync.js';
import { existsSync, readFileSync } from 'fs';

const MD5_A = 'a'.repeat(32);
const MD5_B = 'b'.repeat(32);

function state(slug: string, md5: string): DatasetState {
	return { slug, filename: `${slug}.versatiles`, url: `/${slug}.versatiles`, md5, isRemote: true };
}

describe('checkLocalFiles', () => {
	beforeEach(() => vi.clearAllMocks());

	it('marks a dataset current when the local file and md5 match', () => {
		vi.mocked(existsSync).mockReturnValue(true);
		vi.mocked(readFileSync).mockReturnValue(`${MD5_A}  osm.versatiles\n`);

		const states = [state('osm', MD5_A)];
		const needsUpdate = checkLocalFiles(states, '/tiles');

		expect(needsUpdate).toBe(false);
		expect(states[0].isRemote).toBe(false);
	});

	it('marks a dataset stale on md5 mismatch', () => {
		vi.mocked(existsSync).mockReturnValue(true);
		vi.mocked(readFileSync).mockReturnValue(`${MD5_B}  osm.versatiles\n`);

		const states = [state('osm', MD5_A)];

		expect(checkLocalFiles(states, '/tiles')).toBe(true);
		expect(states[0].isRemote).toBe(true);
	});

	it('marks a dataset stale when the local file is missing', () => {
		// Only the tiles folder exists; the file and its .md5 do not.
		vi.mocked(existsSync).mockImplementation((p) => String(p) === '/tiles');

		const states = [state('osm', MD5_A)];

		expect(checkLocalFiles(states, '/tiles')).toBe(true);
		expect(states[0].isRemote).toBe(true);
	});
});
