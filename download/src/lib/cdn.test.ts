import { describe, it, expect, afterEach, vi } from 'vitest';
import { cdnBaseUrl, parseHash } from './cdn.js';

describe('cdnBaseUrl', () => {
	afterEach(() => vi.unstubAllEnvs());

	it('defaults to https://cdn.versatiles.cloud', () => {
		vi.stubEnv('CDN_BASE_URL', undefined);
		expect(cdnBaseUrl()).toBe('https://cdn.versatiles.cloud');
	});

	it('uses CDN_BASE_URL when set and strips trailing slashes', () => {
		vi.stubEnv('CDN_BASE_URL', 'https://example.test/');
		expect(cdnBaseUrl()).toBe('https://example.test');
	});
});

describe('parseHash', () => {
	it('extracts the leading hash token from a checksum line', () => {
		expect(parseHash('d41d8cd98f00b204e9800998ecf8427e  osm.versatiles')).toBe('d41d8cd98f00b204e9800998ecf8427e');
	});

	it('accepts a bare hash', () => {
		expect(parseHash('d41d8cd98f00b204e9800998ecf8427e')).toBe('d41d8cd98f00b204e9800998ecf8427e');
	});

	it('throws on empty or too-short input', () => {
		expect(() => parseHash('')).toThrow();
		expect(() => parseHash('short')).toThrow();
	});
});
