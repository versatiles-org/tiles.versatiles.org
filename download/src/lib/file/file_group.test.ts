import { describe, it, expect, vi, beforeEach } from 'vitest';
import { hex2base64, groupFiles, collectFiles, FileGroup } from './file_group.js';
import { FileRef } from './file_ref.js';

describe('hex2base64', () => {
	it('converts hex to base64url with padding', () => {
		// "Hello" in hex is 48656c6c6f
		expect(hex2base64('48656c6c6f')).toBe('SGVsbG8=');
	});

	it('handles empty string', () => {
		expect(hex2base64('')).toBe('');
	});

	it('converts md5-like hex strings', () => {
		// d41d8cd98f00b204e9800998ecf8427e is md5 of empty string
		const result = hex2base64('d41d8cd98f00b204e9800998ecf8427e');
		expect(result).toBe('1B2M2Y8AsgTpgAmY7PhCfg==');
	});
});

describe('FileGroup', () => {
	describe('constructor', () => {
		it('creates a group with required properties', () => {
			const group = new FileGroup({
				slug: 'test',
				title: 'Test Group',
				desc: 'A test group',
				order: 1
			});

			expect(group.slug).toBe('test');
			expect(group.title).toBe('Test Group');
			expect(group.desc).toBe('A test group');
			expect(group.order).toBe(1);
			expect(group.local).toBe(false);
			expect(group.latestFile).toBeUndefined();
			expect(group.olderFiles).toEqual([]);
		});

		it('accepts optional local flag', () => {
			const group = new FileGroup({
				slug: 'test',
				title: 'Test',
				desc: 'Test',
				order: 1,
				local: true
			});

			expect(group.local).toBe(true);
		});
	});

	describe('getResponseUrlList', () => {
		it('throws when no latestFile is set', () => {
			const group = new FileGroup({
				slug: 'test',
				title: 'Test',
				desc: 'Test',
				order: 1
			});

			expect(() => group.getResponseUrlList('https://example.com')).toThrow();
		});
	});
});

describe('groupFiles', () => {
	// Mock FileRef for testing
	function createMockFileRef(filename: string, size: number): FileRef {
		const ref = Object.create(FileRef.prototype);
		ref.fullname = `/data/${filename}`;
		ref.filename = filename;
		ref.url = `/${filename}`;
		ref.size = size;
		ref.sizeString = (size / (2 ** 30)).toFixed(1) + ' GB';
		ref.isRemote = true;
		ref.remotePath = `/home/test/${filename}`;
		ref.webdavPath = `/test/${filename}`;
		ref.clone = function() {
			return createMockFileRef(this.filename, this.size);
		};
		return ref;
	}

	it('groups files by slug', () => {
		const files = [
			createMockFileRef('osm.20240101.versatiles', 1000),
			createMockFileRef('osm.20240201.versatiles', 2000),
		];

		const groups = groupFiles(files);

		expect(groups.length).toBe(1);
		expect(groups[0].slug).toBe('osm');
		expect(groups[0].olderFiles.length).toBe(2);
	});

	it('assigns correct metadata to known groups', () => {
		const files = [
			createMockFileRef('osm.20240101.versatiles', 1000),
		];

		const groups = groupFiles(files);

		expect(groups[0].title).toBe('OpenStreetMap as vector tiles');
		expect(groups[0].local).toBe(true);
		expect(groups[0].order).toBe(0);
	});

	it('sorts groups by order', () => {
		const files = [
			createMockFileRef('hillshade-vectors.20240101.versatiles', 1000),
			createMockFileRef('osm.20240101.versatiles', 2000),
			createMockFileRef('landcover-vectors.20240101.versatiles', 3000),
		];

		const groups = groupFiles(files);

		expect(groups[0].slug).toBe('osm');
		expect(groups[1].slug).toBe('hillshade-vectors');
		expect(groups[2].slug).toBe('landcover-vectors');
	});

	it('sets latestFile from most recent file', () => {
		const files = [
			createMockFileRef('osm.20240101.versatiles', 1000),
			createMockFileRef('osm.20240301.versatiles', 3000),
			createMockFileRef('osm.20240201.versatiles', 2000),
		];

		const groups = groupFiles(files);

		expect(groups[0].latestFile).toBeDefined();
		// Latest should be sorted to first (20240301), and URL normalized
		expect(groups[0].latestFile!.url).toBe('/osm.versatiles');
	});

	it('handles unknown groups with warning', () => {
		const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

		const files = [
			createMockFileRef('unknown-dataset.20240101.versatiles', 1000),
		];

		const groups = groupFiles(files);

		expect(groups.length).toBe(1);
		expect(groups[0].slug).toBe('unknown-dataset');
		expect(groups[0].title).toBe('???');
		expect(consoleSpy).toHaveBeenCalledWith('Unknown group "unknown-dataset"');

		consoleSpy.mockRestore();
	});
});

describe('collectFiles', () => {
	function createMockFileRef(url: string): FileRef {
		const ref = Object.create(FileRef.prototype);
		ref.url = url;
		ref.fullname = url;
		ref.filename = url.slice(1);
		ref.size = 1000;
		ref.sizeString = '0.0 GB';
		ref.isRemote = false;
		ref.remotePath = '';
		ref.webdavPath = '';
		return ref;
	}

	it('collects files from FileRef array', () => {
		const files = [
			createMockFileRef('/file1.txt'),
			createMockFileRef('/file2.txt'),
		];

		const result = collectFiles(files);

		expect(result.length).toBe(2);
	});

	it('deduplicates files by url', () => {
		const files = [
			createMockFileRef('/file1.txt'),
			createMockFileRef('/file1.txt'),
			createMockFileRef('/file2.txt'),
		];

		const result = collectFiles(files);

		expect(result.length).toBe(2);
	});

	it('collects files from FileGroup', () => {
		const file1 = createMockFileRef('/latest.txt');
		const file2 = createMockFileRef('/older.txt');

		const group = new FileGroup({
			slug: 'test',
			title: 'Test',
			desc: 'Test',
			order: 1,
			latestFile: file1,
			olderFiles: [file2]
		});

		const result = collectFiles(group);

		expect(result.length).toBe(2);
	});

	it('handles mixed inputs', () => {
		const file1 = createMockFileRef('/file1.txt');
		const file2 = createMockFileRef('/file2.txt');

		const group = new FileGroup({
			slug: 'test',
			title: 'Test',
			desc: 'Test',
			order: 1,
			latestFile: file1
		});

		const result = collectFiles(group, [file2]);

		expect(result.length).toBe(2);
	});
});
