/**
 * Template rendering utilities for generating the HTML and RSS output of
 * download.versatiles.org.
 *
 * All templates are Handlebars files stored under `template/` and receive
 * strongly typed data structures (`FileGroup[]`) as input. This module produces:
 *
 * - `index.html` — the main overview page listing all file groups
 * - `feed-<slug>.xml` — per-group RSS feeds for version updates
 *
 * These outputs are written to disk and wrapped in `FileRef` objects so they
 * can be included in the final NGINX configuration and file inventory.
 */
import { readFileSync, writeFileSync } from 'fs';
import Handlebars from 'handlebars';
import type { FileGroup } from '../file/file_group.js';
import { FileRef } from '../file/file_ref.js';
import { resolve } from 'path';

/**
 * Renders a Handlebars template from the `template/` directory.
 *
 * Parameters:
 * - `fileGroups`: the data passed into the template as `{ fileGroups }`
 * - `templateFilename`: the filename under `template/` (e.g. `"index.html"`)
 *
 * Returns the rendered template as a UTF-8 string.
 *
 * Throws:
 * - If the template file cannot be found or read.
 */
export function renderTemplate(fileGroups: FileGroup[], templateFilename: string): string {
	const templateUrl = new URL(`../../../template/${templateFilename}`, import.meta.url);
	const template = Handlebars.compile(readFileSync(templateUrl, 'utf-8'));
	return template({ fileGroups });
}

/**
 * Generates the main `index.html` file.
 *
 * - Uses the `index.html` Handlebars template.
 * - Writes the result to `filename`.
 * - Wraps the output in a `FileRef` with URL `/index.html` so it becomes part
 *   of the public file set.
 *
 * Logs progress to stdout.
 */
export function generateHTML(fileGroups: FileGroup[], filename: string): FileRef {
	console.log('Generating HTML...');
	writeFileSync(filename, renderTemplate(fileGroups, "index.html"));

	return new FileRef(filename, '/index.html');
}

/**
 * Generates per-group RSS feeds (`feed-<slug>.xml`).
 *
 * For each `FileGroup`:
 * - Renders the `feed.xml` template with a single-element array `[group]`
 * - Writes the output to `<outputDir>/feed-<slug>.xml`
 * - Creates a `FileRef` with URL `/feed-<slug>.xml`
 *
 * Returns the list of all generated `FileRef`s.
 */
export function generateRSSFeeds(fileGroups: FileGroup[], outputDir: string): FileRef[] {
	console.log('Generating RSS feeds...');
	const refs: FileRef[] = []

	fileGroups.forEach(g => {
		const filename = `feed-${g.slug}.xml`
		const outputPath = resolve(outputDir, filename)
		writeFileSync(outputPath, renderTemplate([g], "feed.xml"));
		refs.push(new FileRef(outputPath, '/'+filename))
	})

	return refs;
}
