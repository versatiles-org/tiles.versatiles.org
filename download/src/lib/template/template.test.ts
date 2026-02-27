import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('fs', () => ({
	readFileSync: vi.fn(),
	writeFileSync: vi.fn(),
	renameSync: vi.fn(),
	statSync: vi.fn(() => ({ size: 100 })),
}));

import { renderTemplate, generateRSSFeeds } from './template.js';
import { FileGroup } from '../file/file_group.js';
import { FileRef } from '../file/file_ref.js';
import { readFileSync, writeFileSync, statSync } from 'fs';

describe('renderTemplate', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('renders Handlebars template with data', () => {
		vi.mocked(readFileSync).mockReturnValue('Groups: {{#each fileGroups}}{{this.slug}},{{/each}}');

		const group = new FileGroup({
			slug: 'osm',
			title: 'OSM',
			desc: 'test',
			order: 0,
		});

		const result = renderTemplate([group], 'index.html');
		expect(result).toBe('Groups: osm,');
	});

	it('converts class instances to plain objects via JSON round-trip', () => {
		vi.mocked(readFileSync).mockReturnValue('{{#each fileGroups}}{{this.title}}{{/each}}');

		const group = new FileGroup({
			slug: 'test',
			title: 'Test Title',
			desc: 'desc',
			order: 1,
		});

		const result = renderTemplate([group], 'test.html');
		expect(result).toBe('Test Title');
	});
});

describe('generateRSSFeeds', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		vi.mocked(readFileSync).mockReturnValue('<rss>{{#each fileGroups}}{{this.slug}}{{/each}}</rss>');
		vi.mocked(statSync).mockReturnValue({ size: 50 } as any);
	});

	it('creates feed-<slug>.xml for each group', () => {
		const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

		const groups = [
			new FileGroup({ slug: 'osm', title: 'OSM', desc: 'desc', order: 0 }),
			new FileGroup({ slug: 'hillshade', title: 'Hillshade', desc: 'desc', order: 1 }),
		];

		const refs = generateRSSFeeds(groups, '/output');

		expect(refs).toHaveLength(2);
		expect(writeFileSync).toHaveBeenCalledTimes(2);

		consoleSpy.mockRestore();
	});

	it('returns FileRef array with correct URLs', () => {
		const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

		const groups = [new FileGroup({ slug: 'osm', title: 'OSM', desc: 'desc', order: 0 })];

		const refs = generateRSSFeeds(groups, '/output');

		expect(refs).toHaveLength(1);
		expect(refs[0].url).toBe('/feed-osm.xml');
		expect(refs[0]).toBeInstanceOf(FileRef);

		consoleSpy.mockRestore();
	});
});
