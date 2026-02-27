import { loadFileGroups } from '$lib/data.js';
import type { FileGroupData } from '$lib/data.js';
import type { EntryGenerator, RequestHandler } from './$types.js';

export const prerender = true;

export const entries: EntryGenerator = () => {
	return loadFileGroups().map((g) => ({ slug: g.slug }));
};

function buildRssFeed(group: FileGroupData): string {
	const items = group.olderFiles
		.map(
			(file) =>
				`        <item>
            <title>${file.url}</title>
            <link>https://download.versatiles.org${file.url}</link>
            <guid>${file.filename};${file.hashes.md5}</guid>
            <description>${file.sizeString}</description>
        </item>`,
		)
		.join('\n');

	return `<rss version="2.0">
    <channel>
        <title>Versatiles data releases: ${group.slug}</title>
        <link>https://download.versatiles.org/</link>
        <description>${group.desc}</description>
${items}
    </channel>
</rss>
`;
}

export const GET: RequestHandler = ({ params }) => {
	const groups = loadFileGroups();
	const group = groups.find((g) => g.slug === params.slug);

	if (!group) {
		return new Response('Not found', { status: 404 });
	}

	return new Response(buildRssFeed(group), {
		headers: { 'Content-Type': 'application/rss+xml' },
	});
};
