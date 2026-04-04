import adapter from '@sveltejs/adapter-static';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	kit: {
		adapter: adapter({
			pages: 'build',
			assets: 'build',
			fallback: undefined,
			precompress: false,
			strict: true,
		}),
		prerender: {
			entries: ['*'],
			// File download endpoints (.versatiles, .md5, .tsv, …) are served by
			// nginx in production but don't exist during the vite prerender crawl.
			// Suppress those 404 logs with a no-op handler.
			handleHttpError: () => {},
		},
	},
};

export default config;
