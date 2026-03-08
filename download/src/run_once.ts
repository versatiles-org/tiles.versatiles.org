import { run } from './lib/run.js';

try {
	await run();
} catch (error) {
	console.error('Pipeline failed:', error);
	process.exit(1);
}
