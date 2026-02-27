import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('fs', () => ({
	writeFileSync: vi.fn(),
	renameSync: vi.fn(),
	mkdirSync: vi.fn(),
	readdirSync: vi.fn(() => []),
	copyFileSync: vi.fn(),
	statSync: vi.fn(() => ({ size: 100, isDirectory: () => false })),
}));

vi.mock('child_process', () => ({
	execSync: vi.fn(),
}));

import { generateSite } from './template.js';
import { FileGroup } from '../file/file_group.js';
import { FileRef } from '../file/file_ref.js';
import { writeFileSync, mkdirSync, readdirSync, copyFileSync } from 'fs';
import { execSync } from 'child_process';

function mockBuildOutput() {
	// readdirSync is called twice: once for build/ (files), once for _app/ (contents)
	vi.mocked(readdirSync)
		.mockReturnValueOnce(['feed-osm.xml', 'feed-hillshade.xml', 'other.html', '_app'] as any)
		.mockReturnValueOnce([] as any);
}

describe('generateSite', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('writes data/fileGroups.json with serialised data', () => {
		mockBuildOutput();
		const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

		const groups = [new FileGroup({ slug: 'osm', title: 'OSM', desc: 'test', order: 0 })];

		generateSite(groups, '/output');

		expect(mkdirSync).toHaveBeenCalled();
		expect(writeFileSync).toHaveBeenCalledWith(expect.stringContaining('fileGroups.json'), expect.any(String));

		const dataCall = vi.mocked(writeFileSync).mock.calls.find((c) => String(c[0]).includes('fileGroups.json'));
		expect(dataCall).toBeDefined();
		const parsed = JSON.parse(dataCall![1] as string);
		expect(parsed[0].slug).toBe('osm');

		consoleSpy.mockRestore();
	});

	it('invokes svelte-kit sync and vite build', () => {
		mockBuildOutput();
		const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

		const groups = [new FileGroup({ slug: 'osm', title: 'OSM', desc: 'test', order: 0 })];

		generateSite(groups, '/output');

		expect(execSync).toHaveBeenCalledWith('npx svelte-kit sync', { stdio: 'inherit' });
		expect(execSync).toHaveBeenCalledWith('npx vite build', { stdio: 'inherit' });

		consoleSpy.mockRestore();
	});

	it('copies index.html and feed XML files to content folder', () => {
		mockBuildOutput();
		const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

		const groups = [new FileGroup({ slug: 'osm', title: 'OSM', desc: 'test', order: 0 })];

		generateSite(groups, '/output');

		// index.html copy
		expect(copyFileSync).toHaveBeenCalledWith(expect.stringContaining('index.html'), expect.stringContaining('.tmp'));

		// feed XML copies (only feed-*.xml, not other.html)
		const feedCopyCalls = vi.mocked(copyFileSync).mock.calls.filter((c) => String(c[0]).includes('feed-'));
		expect(feedCopyCalls).toHaveLength(2);

		consoleSpy.mockRestore();
	});

	it('returns correct FileRef objects', () => {
		mockBuildOutput();
		const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

		const groups = [new FileGroup({ slug: 'osm', title: 'OSM', desc: 'test', order: 0 })];

		const { htmlRef, rssRefs } = generateSite(groups, '/output');

		expect(htmlRef).toBeInstanceOf(FileRef);
		expect(htmlRef.url).toBe('/index.html');

		expect(rssRefs).toHaveLength(2);
		expect(rssRefs.map((r) => r.url).sort()).toEqual(['/feed-hillshade.xml', '/feed-osm.xml']);

		consoleSpy.mockRestore();
	});
});
