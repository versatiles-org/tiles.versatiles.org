import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('fs', () => ({
	existsSync: vi.fn(() => true),
	mkdirSync: vi.fn(),
	readdirSync: vi.fn(() => []),
	readFileSync: vi.fn(() => ''),
	statSync: vi.fn(() => ({ size: 100, isFile: () => true })),
	rmSync: vi.fn(),
	renameSync: vi.fn(),
	writeFileSync: vi.fn(),
}));
vi.mock('child_process', () => ({
	spawnSync: vi.fn(() => ({ status: 0 })),
}));

import { syncFiles, downloadLocalFiles } from './sync.js';
import { FileRef } from './file_ref.js';
import { FileGroup } from './file_group.js';
import { existsSync, mkdirSync, rmSync, readdirSync, readFileSync, writeFileSync } from 'fs';
import { spawnSync } from 'child_process';

const FAKE_MD5 = 'd41d8cd98f00b204e9800998ecf8427e';

function createFileRef(filename: string, size: number, remote = true): FileRef {
	if (remote) {
		const remotePath = `/home/data/${filename}`;
		return new FileRef(remotePath, size, remotePath);
	}
	return new FileRef(`/local/${filename}`, size);
}

describe('syncFiles', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		vi.unstubAllEnvs();
		vi.stubEnv('STORAGE_URL', 'user@host');
		vi.mocked(existsSync).mockReturnValue(true);
		vi.mocked(spawnSync).mockReturnValue({ status: 0 } as any);
		vi.spyOn(console, 'log').mockImplementation(() => {});
	});

	it('deletes unwanted files and their hash files', () => {
		const existing = [createFileRef('old.versatiles', 100, false)];
		const wanted: FileRef[] = [];

		vi.mocked(existsSync).mockImplementation((p: any) => {
			if (typeof p === 'string' && (p.endsWith('.md5') || p.endsWith('.sha256'))) return true;
			return true;
		});

		syncFiles(wanted, existing, '/local');

		expect(rmSync).toHaveBeenCalledWith('/local/old.versatiles');
		expect(rmSync).toHaveBeenCalledWith('/local/old.versatiles.md5');
		expect(rmSync).toHaveBeenCalledWith('/local/old.versatiles.sha256');
	});

	it('downloads missing files via SCP', () => {
		const wanted = [createFileRef('new.versatiles', 500)];
		const existing: FileRef[] = [];

		vi.mocked(existsSync).mockImplementation((p: any) => {
			if (p === '/local') return true;
			return false;
		});

		syncFiles(wanted, existing, '/local');

		expect(spawnSync).toHaveBeenCalledWith(
			'scp',
			expect.arrayContaining([expect.stringContaining('new.versatiles')]),
			expect.any(Object),
		);
	});

	it('keeps files with matching hash', () => {
		const wanted = [createFileRef('same.versatiles', 500)];
		wanted[0].hashes = { md5: FAKE_MD5, sha256: 'fake_sha' };
		const existing = [createFileRef('same.versatiles', 500, false)];

		vi.mocked(existsSync).mockReturnValue(true);
		vi.mocked(readFileSync).mockReturnValue(`${FAKE_MD5}  same.versatiles\n`);

		syncFiles(wanted, existing, '/local');

		expect(rmSync).not.toHaveBeenCalled();
		expect(spawnSync).not.toHaveBeenCalled();
	});

	it('re-downloads when hash differs', () => {
		const wanted = [createFileRef('changed.versatiles', 500)];
		wanted[0].hashes = { md5: FAKE_MD5, sha256: 'fake_sha' };
		const existing = [createFileRef('changed.versatiles', 500, false)];

		vi.mocked(existsSync).mockReturnValue(true);
		vi.mocked(readFileSync).mockReturnValue('different_hash  changed.versatiles\n');

		syncFiles(wanted, existing, '/local');

		expect(spawnSync).toHaveBeenCalledWith(
			'scp',
			expect.arrayContaining([expect.stringContaining('changed.versatiles')]),
			expect.any(Object),
		);
		expect(writeFileSync).toHaveBeenCalled();
	});

	it('downloads when no local hash file exists', () => {
		const wanted = [createFileRef('nohash.versatiles', 500)];
		wanted[0].hashes = { md5: FAKE_MD5, sha256: 'fake_sha' };
		const existing = [createFileRef('nohash.versatiles', 500, false)];

		vi.mocked(existsSync).mockImplementation((p: any) => {
			if (typeof p === 'string' && p.endsWith('.md5')) return false;
			return true;
		});

		syncFiles(wanted, existing, '/local');

		expect(spawnSync).toHaveBeenCalledWith(
			'scp',
			expect.arrayContaining([expect.stringContaining('nohash.versatiles')]),
			expect.any(Object),
		);
	});

	it('creates folder if missing', () => {
		vi.mocked(existsSync).mockReturnValue(false);

		syncFiles([], [], '/local');

		expect(mkdirSync).toHaveBeenCalledWith('/local', { recursive: true });
	});
});

describe('downloadLocalFiles', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		vi.unstubAllEnvs();
		vi.stubEnv('STORAGE_URL', 'user@host');
		vi.mocked(existsSync).mockReturnValue(true);
		vi.mocked(readdirSync).mockReturnValue([] as any);
		vi.mocked(spawnSync).mockReturnValue({ status: 0 } as any);
		vi.spyOn(console, 'log').mockImplementation(() => {});
	});

	it('filters groups with local: true and latestFile', async () => {
		const localGroup = new FileGroup({
			slug: 'osm',
			title: 'OSM',
			desc: 'desc',
			order: 0,
			local: true,
			latestFile: createFileRef('osm.versatiles', 1000),
		});

		const remoteGroup = new FileGroup({
			slug: 'hillshade',
			title: 'Hillshade',
			desc: 'desc',
			order: 1,
			local: false,
			latestFile: createFileRef('hillshade.versatiles', 2000),
		});

		const noLatest = new FileGroup({
			slug: 'empty',
			title: 'Empty',
			desc: 'desc',
			order: 2,
			local: true,
		});

		// File doesn't exist on disk so download will be triggered
		vi.mocked(existsSync).mockImplementation((p: any) => {
			if (typeof p === 'string' && p.endsWith('.versatiles')) return false;
			return true;
		});

		await downloadLocalFiles([localGroup, remoteGroup, noLatest], '/local');

		// Only osm.versatiles should be downloaded (local + has latestFile)
		const scpCalls = vi.mocked(spawnSync).mock.calls.filter(([cmd]) => cmd === 'scp');
		expect(scpCalls).toHaveLength(1);
		expect(scpCalls[0][1]).toEqual(expect.arrayContaining([expect.stringContaining('osm.versatiles')]));
	});
});
