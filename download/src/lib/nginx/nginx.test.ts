import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('fs', () => ({
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
		vi.stubEnv('DOMAIN', 'download.example.org');

		const files = [createFileRef('/remote.versatiles', true)];
		const result = buildNginxConf(files, []);

		expect(result).toContain('storage.example.com');
		// Base64 of "myuser:mypass"
		const expectedAuth = Buffer.from('myuser:mypass').toString('base64');
		expect(result).toContain(expectedAuth);
	});

	it('contains server_name directive', () => {
		vi.stubEnv('STORAGE_URL', 'u@h');
		vi.stubEnv('STORAGE_PASS', 'p');
		vi.stubEnv('DOMAIN', 'download.example.org');

		const result = buildNginxConf([], []);

		expect(result).toContain('server_name download.example.org');
	});

	it('separates local vs remote files', () => {
		vi.stubEnv('STORAGE_URL', 'u@h');
		vi.stubEnv('STORAGE_PASS', 'p');
		vi.stubEnv('DOMAIN', 'download.example.org');

		const files = [createFileRef('/local.versatiles', false), createFileRef('/remote.versatiles', true)];

		const result = buildNginxConf(files, []);

		// Local file uses alias
		expect(result).toContain('location = /local.versatiles { alias /local/local.versatiles; }');
		// Remote file uses proxy_pass
		expect(result).toContain('location = /remote.versatiles {');
		expect(result).toContain('proxy_pass https://h/data/remote.versatiles');
	});

	it('sorts deterministically', () => {
		vi.stubEnv('STORAGE_URL', 'u@h');
		vi.stubEnv('STORAGE_PASS', 'p');
		vi.stubEnv('DOMAIN', 'download.example.org');

		const files = [
			createFileRef('/z.versatiles', false),
			createFileRef('/a.versatiles', false),
			createFileRef('/m.versatiles', false),
		];

		const result = buildNginxConf(files, []);

		const aIdx = result.indexOf('/a.versatiles');
		const mIdx = result.indexOf('/m.versatiles');
		const zIdx = result.indexOf('/z.versatiles');
		expect(aIdx).toBeLessThan(mIdx);
		expect(mIdx).toBeLessThan(zIdx);
	});

	it('includes responses in output', () => {
		vi.stubEnv('STORAGE_URL', 'u@h');
		vi.stubEnv('STORAGE_PASS', 'p');
		vi.stubEnv('DOMAIN', 'download.example.org');

		const responses = [new FileResponse('/hash.md5', 'abc123 file\n')];

		const result = buildNginxConf([], responses);

		expect(result).toContain('location = /hash.md5');
		expect(result).toContain('return 200');
	});

	it('contains SSL and security directives', () => {
		vi.stubEnv('STORAGE_URL', 'u@h');
		vi.stubEnv('STORAGE_PASS', 'p');
		vi.stubEnv('DOMAIN', 'download.example.org');

		const result = buildNginxConf([], []);

		expect(result).toContain('ssl_certificate');
		expect(result).toContain('Strict-Transport-Security');
		expect(result).toContain('X-Content-Type-Options');
		expect(result).toContain('limit_conn download_addr');
	});
});
