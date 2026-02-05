import http from 'http';
import { run } from './lib/run.js';

const PORT = parseInt(process.env['PORT'] ?? '8081', 10);

const server = http.createServer((req, res) => {
	if (req.url === '/update' && req.method === 'GET') {
		res.writeHead(202, { 'Content-Type': 'text/plain' });
		res.end('update started');
		console.log('update started');
		run()
			.then(() => console.log('update complete'))
			.catch(err => console.error('update failed:', err));
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
