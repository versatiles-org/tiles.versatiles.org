import { run } from './lib/run.js';

const modeArg = process.argv.find((a) => a.startsWith('--mode='));
const mode = modeArg === '--mode=prepare' ? 'prepare' : 'finalize';

try {
	const needsUpdate = await run({ mode });
	// Exit code 2 signals "nothing to update" so update.sh can skip the
	// intermediate versatiles restart.
	if (mode === 'prepare' && !needsUpdate) process.exit(2);
} catch (error) {
	console.error('Pipeline failed:', error);
	process.exit(1);
}
