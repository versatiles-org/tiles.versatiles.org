import { describe, it, expect, vi, beforeEach } from 'vitest';
import { FileResponse } from './file_response.js';

// Mock child_process and fs before importing
vi.mock('child_process', () => ({
	spawnSync: vi.fn(),
}));
vi.mock('fs', () => ({
	statSync: vi.fn(() => ({ size: 42 })),
}));

import { FileRef, getRemoteFilesViaSSH } from './file_ref.js';
import { spawnSync } from 'child_process';
import { statSync } from 'fs';

describe('FileRef', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	describe('constructor (fullname, url)', () => {
		it('creates a local FileRef with size from statSync', () => {
			vi.mocked(statSync).mockReturnValue({ size: 999 } as any);

			const f = new FileRef('/data/test.versatiles', '/test.versatiles');
			expect(f.fullname).toBe('/data/test.versatiles');
			expect(f.filename).toBe('test.versatiles');
			expect(f.url).toBe('/test.versatiles');
			expect(f.size).toBe(999);
			expect(f.isRemote).toBe(false);
			expect(f.remotePath).toBe('');
			expect(f.webdavPath).toBe('');
		});
	});

	describe('constructor (fullname, size)', () => {
		it('creates a local FileRef with given size', () => {
			const f = new FileRef('/data/test.versatiles', 5000);
			expect(f.fullname).toBe('/data/test.versatiles');
			expect(f.filename).toBe('test.versatiles');
			expect(f.url).toBe('/test.versatiles');
			expect(f.size).toBe(5000);
			expect(f.isRemote).toBe(false);
			expect(f.remotePath).toBe('');
			expect(f.webdavPath).toBe('');
			expect(f.sizeString).toBe('0.0 GB');
		});
	});

	describe('constructor (fullname, size, remotePath)', () => {
		it('creates a remote FileRef', () => {
			const f = new FileRef('/home/osm/data.versatiles', 1e10, '/home/osm/data.versatiles');
			expect(f.fullname).toBe('/home/osm/data.versatiles');
			expect(f.filename).toBe('data.versatiles');
			expect(f.url).toBe('/data.versatiles');
			expect(f.size).toBe(1e10);
			expect(f.isRemote).toBe(true);
			expect(f.remotePath).toBe('/home/osm/data.versatiles');
			expect(f.webdavPath).toBe('/osm/data.versatiles');
		});
	});

	describe('constructor (file) — copy constructor', () => {
		it('copies all fields from another FileRef', () => {
			const original = new FileRef('/data/test.versatiles', 123);
			original.hashes = { md5: 'abc', sha256: 'def' };

			const copy = new FileRef(original);
			expect(copy.fullname).toBe(original.fullname);
			expect(copy.filename).toBe(original.filename);
			expect(copy.url).toBe(original.url);
			expect(copy.size).toBe(original.size);
			expect(copy.isRemote).toBe(original.isRemote);
			expect(copy.remotePath).toBe(original.remotePath);
			expect(copy.webdavPath).toBe(original.webdavPath);
			expect(copy.hashes).toBe(original.hashes);
		});
	});

	describe('url validation', () => {
		it('throws when url does not start with /', () => {
			vi.mocked(statSync).mockReturnValue({ size: 100 } as any);
			expect(() => new FileRef('/data/test.versatiles', 'no-leading-slash')).toThrow(
				"FileRef.url must start with a single '/'",
			);
		});
	});

	describe('md5 getter', () => {
		it('throws when hashes not set', () => {
			const f = new FileRef('/data/test.versatiles', 100);
			expect(() => f.md5).toThrow('MD5 hash is missing');
		});

		it('returns hash when set', () => {
			const f = new FileRef('/data/test.versatiles', 100);
			f.hashes = { md5: 'abc123', sha256: 'def456' };
			expect(f.md5).toBe('abc123');
		});
	});

	describe('sha256 getter', () => {
		it('throws when hashes not set', () => {
			const f = new FileRef('/data/test.versatiles', 100);
			expect(() => f.sha256).toThrow('SHA256 hash is missing');
		});

		it('returns hash when set', () => {
			const f = new FileRef('/data/test.versatiles', 100);
			f.hashes = { md5: 'abc123', sha256: 'def456' };
			expect(f.sha256).toBe('def456');
		});
	});

	describe('getResponseMd5File', () => {
		it('returns a FileResponse with correct url and content', () => {
			const f = new FileRef('/data/test.versatiles', 100);
			f.hashes = { md5: 'abc123', sha256: 'def456' };
			const resp = f.getResponseMd5File();
			expect(resp).toBeInstanceOf(FileResponse);
			expect(resp.url).toBe('/test.versatiles.md5');
			expect(resp.content).toBe('abc123 test.versatiles\\n');
		});
	});

	describe('getResponseSha256File', () => {
		it('returns a FileResponse with correct url and content', () => {
			const f = new FileRef('/data/test.versatiles', 100);
			f.hashes = { md5: 'abc123', sha256: 'def456' };
			const resp = f.getResponseSha256File();
			expect(resp).toBeInstanceOf(FileResponse);
			expect(resp.url).toBe('/test.versatiles.sha256');
			expect(resp.content).toBe('def456 test.versatiles\\n');
		});
	});

	describe('clone', () => {
		it('returns an independent copy', () => {
			const original = new FileRef('/data/test.versatiles', 100);
			const clone = original.clone();
			expect(clone.fullname).toBe(original.fullname);
			expect(clone).not.toBe(original);

			clone.fullname = '/changed';
			expect(original.fullname).toBe('/data/test.versatiles');
		});
	});

	describe('cloneMoved', () => {
		it('remaps fullname for local files', () => {
			const f = new FileRef('/old/dir/test.versatiles', 100);
			const moved = f.cloneMoved('/old/dir', '/new/dir');
			expect(moved.fullname).toBe('/new/dir/test.versatiles');
			expect(moved).not.toBe(f);
		});

		it('does not remap fullname for remote files', () => {
			const f = new FileRef('/home/osm/test.versatiles', 100, '/home/osm/test.versatiles');
			const moved = f.cloneMoved('/home/osm', '/new/dir');
			expect(moved.fullname).toBe('/home/osm/test.versatiles');
		});
	});
});

describe('getRemoteFilesViaSSH', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		vi.unstubAllEnvs();
	});

	it('parses multi-directory ls -lR output', () => {
		vi.stubEnv('STORAGE_URL', 'user@host');
		const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

		const output = [
			'/home/data:',
			'total 100',
			'-rw-r--r-- 1 user group 5000 Jan  1 12:00 file1.versatiles',
			'-rw-r--r-- 1 user group 3000 Jan  2 12:00 file2.versatiles',
			'',
			'/home/other:',
			'total 50',
			'-rw-r--r-- 1 user group 2000 Jan  3 12:00 file3.versatiles',
		].join('\n');

		vi.mocked(spawnSync).mockReturnValue({
			status: 0,
			stdout: output,
			stderr: '',
		} as any);

		const files = getRemoteFilesViaSSH();
		expect(files).toHaveLength(3);
		expect(files[0].fullname).toBe('/home/data/file1.versatiles');
		expect(files[0].size).toBe(5000);
		expect(files[0].isRemote).toBe(true);

		consoleSpy.mockRestore();
	});

	it('filters to .versatiles files only', () => {
		vi.stubEnv('STORAGE_URL', 'user@host');
		const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

		const output = [
			'/home/data:',
			'-rw-r--r-- 1 user group 5000 Jan  1 12:00 file1.versatiles',
			'-rw-r--r-- 1 user group 3000 Jan  2 12:00 file2.txt',
			'-rw-r--r-- 1 user group 2000 Jan  3 12:00 file3.tar.gz',
		].join('\n');

		vi.mocked(spawnSync).mockReturnValue({
			status: 0,
			stdout: output,
			stderr: '',
		} as any);

		const files = getRemoteFilesViaSSH();
		expect(files).toHaveLength(1);
		expect(files[0].filename).toBe('file1.versatiles');

		consoleSpy.mockRestore();
	});

	it('skips directories', () => {
		vi.stubEnv('STORAGE_URL', 'user@host');
		const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

		const output = [
			'/home/data:',
			'drwxr-xr-x 2 user group 4096 Jan  1 12:00 subdir.versatiles',
			'-rw-r--r-- 1 user group 5000 Jan  1 12:00 real.versatiles',
		].join('\n');

		vi.mocked(spawnSync).mockReturnValue({
			status: 0,
			stdout: output,
			stderr: '',
		} as any);

		const files = getRemoteFilesViaSSH();
		expect(files).toHaveLength(1);
		expect(files[0].filename).toBe('real.versatiles');

		consoleSpy.mockRestore();
	});

	it('rejects filenames with path traversal characters', () => {
		vi.stubEnv('STORAGE_URL', 'user@host');
		const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

		const output = [
			'/home/data:',
			'-rw-r--r-- 1 user group 5000 Jan  1 12:00 ../evil.versatiles',
			'-rw-r--r-- 1 user group 5000 Jan  1 12:00 sub/dir.versatiles',
			'-rw-r--r-- 1 user group 5000 Jan  1 12:00 good.versatiles',
		].join('\n');

		vi.mocked(spawnSync).mockReturnValue({
			status: 0,
			stdout: output,
			stderr: '',
		} as any);

		const files = getRemoteFilesViaSSH();
		expect(files).toHaveLength(1);
		expect(files[0].filename).toBe('good.versatiles');

		consoleSpy.mockRestore();
	});

	it('throws on missing STORAGE_URL', () => {
		vi.stubEnv('STORAGE_URL', '');
		// Also delete to ensure it's truly missing
		delete process.env['STORAGE_URL'];

		expect(() => getRemoteFilesViaSSH()).toThrow('STORAGE_URL environment variable is not set');
	});

	it('throws on SSH failure', () => {
		vi.stubEnv('STORAGE_URL', 'user@host');
		const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

		vi.mocked(spawnSync).mockReturnValue({
			status: 1,
			stdout: '',
			stderr: 'connection refused',
		} as any);

		expect(() => getRemoteFilesViaSSH()).toThrow('Failed to scan remote storage via SSH');

		consoleSpy.mockRestore();
	});

	it('sorts results by fullname', () => {
		vi.stubEnv('STORAGE_URL', 'user@host');
		const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

		const output = [
			'/home/data:',
			'-rw-r--r-- 1 user group 5000 Jan  1 12:00 z-file.versatiles',
			'-rw-r--r-- 1 user group 3000 Jan  2 12:00 a-file.versatiles',
		].join('\n');

		vi.mocked(spawnSync).mockReturnValue({
			status: 0,
			stdout: output,
			stderr: '',
		} as any);

		const files = getRemoteFilesViaSSH();
		expect(files[0].fullname).toBe('/home/data/a-file.versatiles');
		expect(files[1].fullname).toBe('/home/data/z-file.versatiles');

		consoleSpy.mockRestore();
	});
});
