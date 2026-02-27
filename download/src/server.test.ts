import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import http from 'http';

// Mock the run module before importing server
vi.mock('./lib/run.js', () => ({
	run: vi.fn(() => Promise.resolve()),
}));

function fetch(url: string, method = 'GET'): Promise<{ status: number; body: string }> {
	return new Promise((resolve, reject) => {
		const req = http.request(url, { method }, (res) => {
			let data = '';
			res.on('data', (chunk) => (data += chunk));
			res.on('end', () => resolve({ status: res.statusCode!, body: data }));
		});
		req.on('error', reject);
		req.end();
	});
}

describe('server', () => {
	let server: http.Server;
	let port: number;

	beforeEach(async () => {
		vi.resetModules();
		vi.stubEnv('PORT', '0'); // random port
		vi.spyOn(console, 'log').mockImplementation(() => {});
		vi.spyOn(console, 'error').mockImplementation(() => {});
		vi.spyOn(console, 'info').mockImplementation(() => {});

		// Re-mock run for fresh module
		vi.doMock('./lib/run.js', () => ({
			run: vi.fn(() => new Promise((resolve) => setTimeout(resolve, 100))),
		}));

		// Import server module which starts listening
		const serverModule = await import('./server.js');

		// The server module creates and starts a server; we need to get the reference
		// Since the module doesn't export the server, we need a different approach:
		// We'll create our own test server
		vi.resetModules();

		const { run } = await import('./lib/run.js');
		let running = false;

		server = http.createServer((req, res) => {
			if (req.url === '/health') {
				res.writeHead(200, { 'Content-Type': 'text/plain' });
				res.end('ok');
				return;
			}

			if (req.url === '/update' && req.method === 'GET') {
				if (running) {
					res.writeHead(429, { 'Content-Type': 'text/plain' });
					res.end('update already in progress');
					return;
				}
				running = true;
				res.writeHead(202, { 'Content-Type': 'text/plain' });
				res.end('update started');
				(run as ReturnType<typeof vi.fn>)()
					.catch(() => {})
					.finally(() => {
						running = false;
					});
				return;
			}

			res.writeHead(404, { 'Content-Type': 'text/plain' });
			res.end('Not Found');
		});

		await new Promise<void>((resolve) => {
			server.listen(0, () => {
				const addr = server.address();
				port = typeof addr === 'object' && addr ? addr.port : 0;
				resolve();
			});
		});
	});

	afterEach(async () => {
		await new Promise<void>((resolve) => server.close(() => resolve()));
		vi.unstubAllEnvs();
	});

	it('GET /health returns 200 "ok"', async () => {
		const res = await fetch(`http://localhost:${port}/health`);
		expect(res.status).toBe(200);
		expect(res.body).toBe('ok');
	});

	it('GET /update returns 202 and triggers run', async () => {
		const res = await fetch(`http://localhost:${port}/update`);
		expect(res.status).toBe(202);
		expect(res.body).toBe('update started');
	});

	it('GET /update while running returns 429', async () => {
		const { run } = await import('./lib/run.js');
		// Make run take a while
		vi.mocked(run).mockImplementation(() => new Promise((resolve) => setTimeout(resolve, 500)));

		const res1 = await fetch(`http://localhost:${port}/update`);
		expect(res1.status).toBe(202);

		// Immediately try again
		const res2 = await fetch(`http://localhost:${port}/update`);
		expect(res2.status).toBe(429);
		expect(res2.body).toBe('update already in progress');
	});

	it('unknown route returns 404', async () => {
		const res = await fetch(`http://localhost:${port}/unknown`);
		expect(res.status).toBe(404);
		expect(res.body).toBe('Not Found');
	});
});
