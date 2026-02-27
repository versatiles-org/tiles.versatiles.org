import http from 'http';
import { run } from './lib/run.js';

const PORT = parseInt(process.env['PORT'] ?? '8081', 10);

let running = false;

const server = http.createServer((req, res) => {
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
		console.log('update started');
		run()
			.then(() => console.log('update complete'))
			.catch(err => console.error('update failed:', err))
			.finally(() => { running = false; });
		return;
	}

	res.writeHead(404, { 'Content-Type': 'text/plain' });
	res.end('Not Found');
});

server.listen(PORT, () => {
	console.log(`listening on http://localhost:${PORT}/`);
});

process.on('SIGINT', () => {
	console.info('Interrupted');
	process.exit(0);
});
