import { describe, it, expect, vi, beforeEach } from 'vitest';
import { EventEmitter } from 'events';

vi.mock('fs', () => ({
	existsSync: vi.fn(),
	mkdirSync: vi.fn(),
	readdirSync: vi.fn(() => []),
	readFileSync: vi.fn(),
	writeFileSync: vi.fn(),
	unlinkSync: vi.fn(),
	rmSync: vi.fn(),
}));
vi.mock('child_process', () => ({
	spawn: vi.fn(),
}));

import { generateHashes } from './hashes.js';
import { FileRef } from './file_ref.js';
import { existsSync, readFileSync, writeFileSync } from 'fs';
import { spawn } from 'child_process';

const FAKE_MD5 = 'd41d8cd98f00b204e9800998ecf8427e'; // 32 chars
const FAKE_SHA = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'; // 64 chars

function createFileRef(filename: string, remotePath: string): FileRef {
	const ref = new FileRef(remotePath, 1000, remotePath);
	ref.filename = filename;
	ref.url = '/' + filename;
	return ref;
}

/** Creates a mock child process that emits stdout data and closes with given code */
function mockProcess(stdout: string, code: number) {
	const proc = new EventEmitter();
	(proc as any).stdout = new EventEmitter();
	(proc as any).stderr = new EventEmitter();
	process.nextTick(() => {
		if (stdout) (proc as any).stdout.emit('data', Buffer.from(stdout));
		proc.emit('close', code);
	});
	return proc;
}

describe('generateHashes', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		vi.unstubAllEnvs();
		vi.stubEnv('STORAGE_URL', 'user@host');
		vi.spyOn(console, 'log').mockImplementation(() => {});
	});

	it('uses cached hash when file exists', async () => {
		const file = createFileRef('test.versatiles', '/home/data/test.versatiles');

		vi.mocked(existsSync).mockReturnValue(true);
		vi.mocked(readFileSync).mockImplementation((p: any) => {
			if (typeof p === 'string' && p.endsWith('.md5')) return `${FAKE_MD5} test.versatiles\n`;
			if (typeof p === 'string' && p.endsWith('.sha256')) return `${FAKE_SHA} test.versatiles\n`;
			return '';
		});

		await generateHashes([file]);

		expect(spawn).not.toHaveBeenCalled();
		expect(file.hashes).toEqual({ md5: FAKE_MD5, sha256: FAKE_SHA });
	});

	it('downloads hash file from remote when no cache', async () => {
		const file = createFileRef('test.versatiles', '/home/data/test.versatiles');

		vi.mocked(existsSync).mockImplementation((p: any) => {
			if (typeof p === 'string' && (p.endsWith('.md5') || p.endsWith('.sha256'))) return false;
			return true;
		});

		vi.mocked(spawn).mockImplementation((_cmd: any, args: any) => {
			if (args && Array.isArray(args) && args.includes('cat')) {
				const hashPath = args[args.length - 1] as string;
				if (hashPath.endsWith('.md5')) {
					return mockProcess(`${FAKE_MD5}  test.versatiles\n`, 0) as any;
				}
				if (hashPath.endsWith('.sha256')) {
					return mockProcess(`${FAKE_SHA}  test.versatiles\n`, 0) as any;
				}
			}
			return mockProcess('', 1) as any;
		});

		vi.mocked(readFileSync).mockImplementation((p: any) => {
			if (typeof p === 'string' && p.endsWith('.md5')) return `${FAKE_MD5} test.versatiles\n`;
			if (typeof p === 'string' && p.endsWith('.sha256')) return `${FAKE_SHA} test.versatiles\n`;
			return '';
		});

		await generateHashes([file]);

		expect(writeFileSync).toHaveBeenCalledTimes(2);
		expect(file.hashes).toEqual({ md5: FAKE_MD5, sha256: FAKE_SHA });
	});

	it('calculates hash remotely and stores on remote when download fails', async () => {
		const file = createFileRef('test.versatiles', '/home/data/test.versatiles');

		vi.mocked(existsSync).mockImplementation((p: any) => {
			if (typeof p === 'string' && (p.endsWith('.md5') || p.endsWith('.sha256'))) return false;
			return true;
		});

		vi.mocked(spawn).mockImplementation((cmd: any, args: any) => {
			if (cmd === 'scp') {
				return mockProcess('', 0) as any;
			}
			if (args && Array.isArray(args)) {
				if (args.includes('cat')) {
					return mockProcess('', 1) as any;
				}
				if (args.includes('md5sum')) {
					return mockProcess(`${FAKE_MD5}  /home/data/test.versatiles\n`, 0) as any;
				}
				if (args.includes('sha256sum')) {
					return mockProcess(`${FAKE_SHA}  /home/data/test.versatiles\n`, 0) as any;
				}
			}
			return mockProcess('', 1) as any;
		});

		vi.mocked(readFileSync).mockImplementation((p: any) => {
			if (typeof p === 'string' && p.endsWith('.md5')) return `${FAKE_MD5} test.versatiles\n`;
			if (typeof p === 'string' && p.endsWith('.sha256')) return `${FAKE_SHA} test.versatiles\n`;
			return '';
		});

		await generateHashes([file]);

		// Should write to local cache (2) + temp files for SCP upload (2) = 4
		expect(writeFileSync).toHaveBeenCalledTimes(4);
		expect(file.hashes).toEqual({ md5: FAKE_MD5, sha256: FAKE_SHA });

		// Verify SCP was called to upload hash files to remote
		const scpCalls = vi.mocked(spawn).mock.calls.filter(([cmd]) => cmd === 'scp');
		expect(scpCalls).toHaveLength(2);
	});

	it('throws when both download and calculation fail', async () => {
		const file = createFileRef('test.versatiles', '/home/data/test.versatiles');

		vi.mocked(existsSync).mockImplementation((p: any) => {
			if (typeof p === 'string' && (p.endsWith('.md5') || p.endsWith('.sha256'))) return false;
			return true;
		});

		vi.mocked(spawn).mockImplementation(() => {
			return mockProcess('', 1) as any;
		});

		await expect(generateHashes([file])).rejects.toThrow(
			'Failed to calculate md5 for /home/data/test.versatiles on remote',
		);
	});

	it('sets file.hashes on each FileRef', async () => {
		const file1 = createFileRef('a.versatiles', '/home/data/a.versatiles');
		const file2 = createFileRef('b.versatiles', '/home/data/b.versatiles');

		vi.mocked(existsSync).mockReturnValue(true);
		vi.mocked(readFileSync).mockImplementation((p: any) => {
			if (typeof p === 'string' && p.includes('/a.versatiles.md5')) return `${FAKE_MD5} a.versatiles\n`;
			if (typeof p === 'string' && p.includes('/a.versatiles.sha256')) return `${FAKE_SHA} a.versatiles\n`;
			if (typeof p === 'string' && p.includes('/b.versatiles.md5')) return `${FAKE_MD5} b.versatiles\n`;
			if (typeof p === 'string' && p.includes('/b.versatiles.sha256')) return `${FAKE_SHA} b.versatiles\n`;
			return '';
		});

		await generateHashes([file1, file2]);

		expect(file1.hashes).toEqual({ md5: FAKE_MD5, sha256: FAKE_SHA });
		expect(file2.hashes).toEqual({ md5: FAKE_MD5, sha256: FAKE_SHA });
	});
});
