import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('fs', () => ({
	existsSync: vi.fn(() => true),
	mkdirSync: vi.fn(),
	readdirSync: vi.fn(() => []),
	statSync: vi.fn(() => ({ size: 100, isFile: () => true })),
	rmSync: vi.fn(),
	renameSync: vi.fn(),
}));
vi.mock('child_process', () => ({
	spawnSync: vi.fn(() => ({ status: 0 })),
}));

import { syncFiles, downloadLocalFiles } from './sync.js';
import { FileRef } from './file_ref.js';
import { FileGroup } from './file_group.js';
import { existsSync, mkdirSync, rmSync, readdirSync } from 'fs';
import { spawnSync } from 'child_process';

function createFileRef(filename: string, size: number, remote = true): FileRef {
	const ref = Object.create(FileRef.prototype) as FileRef;
	ref.fullname = remote ? `/home/data/${filename}` : `/local/${filename}`;
	ref.filename = filename;
	ref.url = '/' + filename;
	ref.size = size;
	ref.sizeString = (size / (2 ** 30)).toFixed(1) + ' GB';
	ref.isRemote = remote;
	ref.remotePath = remote ? `/home/data/${filename}` : '';
	ref.webdavPath = remote ? `/data/${filename}` : '';
	return ref;
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

	it('deletes unwanted files', () => {
		const existing = [createFileRef('old.versatiles', 100, false)];
		const wanted: FileRef[] = [];

		syncFiles(wanted, existing, '/local');

		expect(rmSync).toHaveBeenCalledWith('/local/old.versatiles');
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

	it('keeps files with matching size', () => {
		const wanted = [createFileRef('same.versatiles', 500)];
		const existing = [createFileRef('same.versatiles', 500, false)];

		vi.mocked(existsSync).mockReturnValue(true);

		syncFiles(wanted, existing, '/local');

		expect(rmSync).not.toHaveBeenCalled();
		expect(spawnSync).not.toHaveBeenCalled();
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
		const scpCalls = vi.mocked(spawnSync).mock.calls.filter(
			([cmd]) => cmd === 'scp'
		);
		expect(scpCalls).toHaveLength(1);
		expect(scpCalls[0][1]).toEqual(
			expect.arrayContaining([expect.stringContaining('osm.versatiles')])
		);
	});
});
