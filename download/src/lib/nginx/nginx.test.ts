import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('fs', () => ({
	readFileSync: vi.fn(() => '{{{webhook}}}|{{{domain}}}|{{{webdavHost}}}|{{{webdavAuth}}}|{{#each localFiles}}L:{{{this.url}}},{{/each}}{{#each remoteFiles}}R:{{{this.url}}},{{/each}}{{#each responses}}V:{{{this.url}}},{{/each}}'),
	writeFileSync: vi.fn(),
	renameSync: vi.fn(),
}));

import { buildNginxConf } from './nginx.js';
import { FileRef } from '../file/file_ref.js';
import { FileResponse } from '../file/file_response.js';

function createFileRef(url: string, isRemote: boolean): FileRef {
	const ref = Object.create(FileRef.prototype) as FileRef;
	ref.fullname = isRemote ? `/home/data${url}` : `/local${url}`;
	ref.filename = url.slice(1);
	ref.url = url;
	ref.size = 1000;
	ref.sizeString = '0.0 GB';
	ref.isRemote = isRemote;
	ref.remotePath = isRemote ? `/home/data${url}` : '';
	ref.webdavPath = isRemote ? `/data${url}` : '';
	return ref;
}

describe('buildNginxConf', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		vi.unstubAllEnvs();
	});

	it('parses STORAGE_URL to extract webdav host and auth', () => {
		vi.stubEnv('STORAGE_URL', 'myuser@storage.example.com');
		vi.stubEnv('STORAGE_PASS', 'mypass');
		vi.stubEnv('WEBHOOK', '');
		vi.stubEnv('DOMAIN', '');

		const result = buildNginxConf([], []);

		expect(result).toContain('storage.example.com');
		// Base64 of "myuser:mypass"
		const expectedAuth = Buffer.from('myuser:mypass').toString('base64');
		expect(result).toContain(expectedAuth);
	});

	it('separates local vs remote files', () => {
		vi.stubEnv('STORAGE_URL', 'u@h');
		vi.stubEnv('STORAGE_PASS', 'p');
		vi.stubEnv('WEBHOOK', '');
		vi.stubEnv('DOMAIN', '');

		const files = [
			createFileRef('/local.versatiles', false),
			createFileRef('/remote.versatiles', true),
		];

		const result = buildNginxConf(files, []);

		expect(result).toContain('L:/local.versatiles,');
		expect(result).toContain('R:/remote.versatiles,');
		// local should not appear in remote list
		expect(result).not.toContain('R:/local.versatiles');
		expect(result).not.toContain('L:/remote.versatiles');
	});

	it('sorts deterministically', () => {
		vi.stubEnv('STORAGE_URL', 'u@h');
		vi.stubEnv('STORAGE_PASS', 'p');
		vi.stubEnv('WEBHOOK', '');
		vi.stubEnv('DOMAIN', '');

		const files = [
			createFileRef('/z.versatiles', false),
			createFileRef('/a.versatiles', false),
			createFileRef('/m.versatiles', false),
		];

		const result = buildNginxConf(files, []);

		const localPart = result.match(/L:[^|]*/)?.[0] ?? '';
		expect(localPart).toBe('L:/a.versatiles,L:/m.versatiles,L:/z.versatiles,');
	});

	it('passes webhook and domain to template', () => {
		vi.stubEnv('STORAGE_URL', 'u@h');
		vi.stubEnv('STORAGE_PASS', 'p');
		vi.stubEnv('WEBHOOK', 'https://hook.example.com');
		vi.stubEnv('DOMAIN', 'download.example.org');

		const result = buildNginxConf([], []);

		expect(result).toContain('https://hook.example.com');
		expect(result).toContain('download.example.org');
	});

	it('includes responses in output', () => {
		vi.stubEnv('STORAGE_URL', 'u@h');
		vi.stubEnv('STORAGE_PASS', 'p');
		vi.stubEnv('WEBHOOK', '');
		vi.stubEnv('DOMAIN', '');

		const responses = [
			new FileResponse('/hash.md5', 'abc123 file\n'),
		];

		const result = buildNginxConf([], responses);

		expect(result).toContain('V:/hash.md5,');
	});
});
