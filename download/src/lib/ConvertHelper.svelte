<script lang="ts">
	import type { FileRefData } from './data.js';

	let { file }: { file: FileRefData } = $props();

	let format: 'versatiles' | 'pmtiles' | 'mbtiles' | 'tar' = $state('pmtiles');
	let tool: 'versatiles' | 'docker' = $state('versatiles');
	let copied = $state(false);

	let dialog: HTMLDialogElement;

	const baseName = $derived(file.filename.replace(/\.versatiles$/, ''));
	const outputFile = $derived(`${baseName}.${format}`);
	const fullUrl = $derived(`https://download.versatiles.org${file.url}`);
	function buildCommand(t: typeof tool, source: string, output: string): string {
		let parts: string[] = [];
		switch (t) {
			case 'versatiles':
				parts.push('versatiles convert');
				break;
			case 'docker':
				parts.push('docker run -it --rm -v $(pwd):/data', 'versatiles/versatiles:latest convert');
				break;
		}
		parts.push(`"${source}"`, `"${t == 'docker' ? '/data/' : ''}${output}"`);
		return parts.join(' \\\n  ');
	}

	const command = $derived(buildCommand(tool, fullUrl, outputFile));

	function open() {
		dialog.showModal();
	}

	function close() {
		dialog.close();
	}

	function backdropClick(e: MouseEvent) {
		if (e.target === dialog) close();
	}

	async function copy() {
		await navigator.clipboard.writeText(command);
		copied = true;
		setTimeout(() => (copied = false), 1500);
	}

	const formats = ['versatiles', 'pmtiles', 'mbtiles', 'tar'] as const;
</script>

<button class="convert-btn" onclick={open} title="Convert to other format">&hellip;</button>

<dialog bind:this={dialog} onclick={backdropClick}>
	<div class="dialog-content">
		<div class="dialog-header">
			<span>Download <strong>{baseName}</strong></span>
			<button class="close-btn" onclick={close}>&#x2715;</button>
		</div>

		<span class="label">Select a format:</span>
		<div class="toggle-format">
			{#each formats as f}
				<button class:active={format === f} onclick={() => (format = f)}>.{f}</button>
			{/each}
		</div>

		<div class="toggle-tool">
			<span class="label">Select a tool:</span>
			<div class="toggles">
				<button class:active={tool === 'versatiles'} onclick={() => (tool = 'versatiles')}>versatiles binary</button>
				<a
					class="install-link"
					href="https://docs.versatiles.org/guides/install_versatiles.html"
					target="_blank"
					rel="noopener noreferrer"
					title="Installation instructions">&#x2197;</a
				>
				<button class:active={tool === 'docker'} onclick={() => (tool = 'docker')}>docker</button>
			</div>
		</div>

		<div class="command-row">
			<span class="label">Run this command:</span>
			<pre><code>{command}</code></pre>
			<button class="copy-btn" onclick={copy}>{copied ? 'Copied!' : 'Copy'}</button>
		</div>
	</div>
</dialog>

<style lang="scss">
	.convert-btn {
		background: none;
		border: none;
		color: #888;
		cursor: pointer;
		font-size: 0.85em;
		padding: 0 0.2em;
		line-height: 1;

		&:hover {
			color: #fff;
		}
	}

	dialog {
		background: #1a1a1a;
		color: #ccc;
		border: 1px solid #333;
		border-radius: 8px;
		padding: 0;
		max-width: 90vw;
		width: 40rem;

		&::backdrop {
			background: rgba(0, 0, 0, 0.7);
		}
	}

	.dialog-content {
		padding: 1.2em;
	}

	.dialog-header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		margin-bottom: 0.8em;
		font-size: 1.1em;

		strong {
			color: #fff;
		}
	}

	.close-btn {
		background: none;
		border: none;
		color: #ccc;
		font-size: 1.2em;
		cursor: pointer;
		padding: 0.2em 0.4em;

		&:hover {
			color: #fff;
		}
	}

	.toggle-format {
		display: flex;
		gap: 0.4em;
		flex-wrap: wrap;
		margin-bottom: 1em;

		button {
			background: #333;
			border: none;
			color: #ccc;
			padding: 0.4em 0.9em;
			cursor: pointer;
			border-radius: 4px;
			font-size: 0.95em;

			&:hover {
				background: #444;
			}

			&.active {
				background: #555;
				color: #fff;
			}
		}
	}

	.toggle-tool {
		margin-bottom: 2em;
	}

	.label {
		display: block;
		margin-bottom: 0.4em;
		opacity: 0.6;
		font-size: 0.9em;
	}

	.toggles {
		display: flex;
		gap: 0.4em;
		align-items: center;

		button {
			background: #333;
			border: none;
			color: #ccc;
			padding: 0.3em 0.8em;
			cursor: pointer;
			border-radius: 4px;
			font-size: 0.9em;

			&:hover {
				background: #444;
			}

			&.active {
				background: #555;
				color: #fff;
			}
		}
	}

	.install-link {
		font-size: 0.9em;
		opacity: 0.4;
		margin-right: 1em;

		&:hover {
			opacity: 0.8;
		}
	}

	.command-row {
		display: flex;
		flex-direction: column;
		gap: 0em;
	}

	pre {
		flex: 1;
		background: #080808;
		padding: 0.4em 0.6em;
		border-radius: 4px;
		overflow-x: auto;
		margin: 0;
		font-size: 0.6em;
		line-height: 1.5em;
	}

	code {
		font-family: 'SF Mono', 'Fira Code', 'Fira Mono', 'Roboto Mono', monospace;
	}

	.copy-btn {
		background: #333;
		border: none;
		color: #ccc;
		padding: 0.5em 1em;
		cursor: pointer;
		border-radius: 4px;
		font-size: 0.85em;
		white-space: nowrap;

		&:hover {
			background: #444;
		}
	}
</style>
