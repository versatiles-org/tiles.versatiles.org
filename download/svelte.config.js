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
			// Safety net: don't fail the build on prerender HTTP errors. Static
			// download files (.versatiles, .md5, .tsv, …) are served by nginx in
			// production and have no SvelteKit route — their <a> tags use
			// rel="external" so the prerender crawler skips them, but if one is
			// ever added without the attribute we don't want the whole build to
			// crash on it.
			handleHttpError: () => {},
		},
	},
};

export default config;
