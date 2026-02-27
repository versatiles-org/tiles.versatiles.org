import { describe, it, expect } from 'vitest';
import { FileResponse } from './file_response.js';

describe('FileResponse', () => {
	describe('constructor', () => {
		it('accepts a valid URL and stores content', () => {
			const r = new FileResponse('/test.txt', 'hello');
			expect(r.url).toBe('/test.txt');
			expect(r.content).toBe('hello');
		});

		it('throws when URL does not start with /', () => {
			expect(() => new FileResponse('test.txt', 'hello')).toThrow(
				"FileResponse.url must start with '/', got: test.txt",
			);
		});

		it('handles empty content', () => {
			const r = new FileResponse('/empty', '');
			expect(r.content).toBe('');
		});
	});

	describe('escaping', () => {
		it('escapes backslashes', () => {
			const r = new FileResponse('/a', 'a\\b');
			expect(r.content).toBe('a\\\\b');
		});

		it('escapes double quotes', () => {
			const r = new FileResponse('/a', 'say "hi"');
			expect(r.content).toBe('say \\"hi\\"');
		});

		it('escapes dollar signs', () => {
			const r = new FileResponse('/a', 'cost $5');
			expect(r.content).toBe('cost \\$5');
		});

		it('escapes newlines', () => {
			const r = new FileResponse('/a', 'line1\nline2');
			expect(r.content).toBe('line1\\nline2');
		});

		it('escapes tabs', () => {
			const r = new FileResponse('/a', 'col1\tcol2');
			expect(r.content).toBe('col1\\tcol2');
		});

		it('escapes backslash before other characters to avoid double-escaping', () => {
			// A literal backslash followed by n: should become \\n not \n
			const r = new FileResponse('/a', '\\\n');
			expect(r.content).toBe('\\\\\\n');
		});

		it('handles multiple escape types together', () => {
			const r = new FileResponse('/a', 'a\\b"c$d\ne\tf');
			expect(r.content).toBe('a\\\\b\\"c\\$d\\ne\\tf');
		});
	});
});
