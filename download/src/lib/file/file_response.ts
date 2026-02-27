/**
 * Represents a virtual file served by nginx.
 *
 * This is not an HTTP response. Instead, it models small text payloads
 * generated at build time (e.g. metadata, redirect stubs, integrity info)
 * that nginx later embeds directly in the config.
 *
 * The content is escaped so it can be safely injected into the nginx template.
 * - `\n` becomes `\\n`
 * - `\t` becomes `\\t`
 *
 * The `url` must be an absolute path (starting with '/').
 */
export class FileResponse {
	readonly url: string;
	readonly content: string;

	constructor(url: string, content: string) {
		if (!url.startsWith('/')) {
			throw new Error(`FileResponse.url must start with '/', got: ${url}`);
		}

		this.url = url;

		// Escape for nginx config embedding (inside `return 200 "..."` directives)
		this.content = content
			.replaceAll('\\', '\\\\')
			.replaceAll('"', '\\"')
			.replaceAll('$', '\\$')
			.replaceAll('\n', '\\n')
			.replaceAll('\t', '\\t');
	}
}
