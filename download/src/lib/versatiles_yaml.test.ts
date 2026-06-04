import { describe, it, expect, afterEach, vi } from 'vitest';
import { buildVersatilesYaml } from './versatiles_yaml.js';
import type { DatasetState } from './sync.js';

function state(slug: string, isRemote: boolean): DatasetState {
	return { slug, filename: `${slug}.versatiles`, url: `/${slug}.versatiles`, md5: 'x'.repeat(32), isRemote };
}

describe('buildVersatilesYaml', () => {
	afterEach(() => vi.unstubAllEnvs());

	it('uses local paths for current datasets and CDN URLs for stale ones', () => {
		vi.stubEnv('CDN_BASE_URL', 'https://cdn.versatiles.cloud');

		const yaml = buildVersatilesYaml([state('osm', false), state('satellite', true)]);

		expect(yaml).toContain('  - name: osm\n    src: /data/tiles/osm.versatiles');
		expect(yaml).toContain('  - name: satellite\n    src: https://cdn.versatiles.cloud/satellite.versatiles');
		expect(yaml).toContain('port: 8080');
	});

	it('honours CDN_BASE_URL for the fallback URL', () => {
		vi.stubEnv('CDN_BASE_URL', 'https://mirror.test/');

		const yaml = buildVersatilesYaml([state('osm', true)]);

		expect(yaml).toContain('src: https://mirror.test/osm.versatiles');
	});
});
