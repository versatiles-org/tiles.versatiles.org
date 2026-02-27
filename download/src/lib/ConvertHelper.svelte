<script lang="ts">
	let { url, filename }: { url: string; filename: string } = $props();

	let format: 'versatiles' | 'pmtiles' | 'mbtiles' | 'tar' = $state('pmtiles');
	let tool: 'versatiles' | 'docker' = $state('versatiles');
	let copied = $state(false);

	let dialog: HTMLDialogElement;

	const baseName = $derived(filename.replace(/\.versatiles$/, ''));
	const outputFile = $derived(`${baseName}.${format}`);
	const fullUrl = $derived(`https://download.versatiles.org${url}`);
	const command = $derived(
		tool === 'versatiles'
			? `versatiles convert "${fullUrl}" "${outputFile}"`
			: `docker run -it --rm -v $(pwd):/data versatiles/versatiles:latest convert "${fullUrl}" "/data/${outputFile}"`,
	);

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

<button class="convert-btn" onclick={open} title="Convert to other format">&#x21C4;</button>

<dialog bind:this={dialog} onclick={backdropClick}>
	<div class="dialog-content">
		<div class="dialog-header">
			<span>Download <strong>{baseName}</strong> as</span>
			<button class="close-btn" onclick={close}>&#x2715;</button>
		</div>

		<div class="format-toggles">
			{#each formats as f}
				<button class:active={format === f} onclick={() => (format = f)}>.{f}</button>
			{/each}
		</div>

		<div class="field">
			<span class="label">Using:</span>
			<div class="tool-row">
				<div class="toggles">
					<button class:active={tool === 'versatiles'} onclick={() => (tool = 'versatiles')}>versatiles</button>
					<button class:active={tool === 'docker'} onclick={() => (tool = 'docker')}>docker</button>
				</div>
				{#if tool === 'versatiles'}
					<a
						class="install-link"
						href="https://docs.versatiles.org/guides/install_versatiles.html"
						target="_blank"
						rel="noopener noreferrer">installation instructions &#x2197;</a
					>
				{/if}
			</div>
		</div>

		<div class="command-row">
			<pre><code>{command}</code></pre>
			<button class="copy-btn" onclick={copy}>{copied ? 'Copied!' : 'Copy'}</button>
		</div>
	</div>
</dialog>

<style>
	.convert-btn {
		background: none;
		border: none;
		color: #888;
		cursor: pointer;
		font-size: 0.85em;
		padding: 0 0.2em;
		line-height: 1;
	}

	.convert-btn:hover {
		color: #fff;
	}

	dialog {
		background: #1a1a1a;
		color: #ccc;
		border: 1px solid #333;
		border-radius: 8px;
		padding: 0;
		max-width: 90vw;
		width: 40rem;
	}

	dialog::backdrop {
		background: rgba(0, 0, 0, 0.7);
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
	}

	.dialog-header strong {
		color: #fff;
	}

	.close-btn {
		background: none;
		border: none;
		color: #ccc;
		font-size: 1.2em;
		cursor: pointer;
		padding: 0.2em 0.4em;
	}

	.close-btn:hover {
		color: #fff;
	}

	.format-toggles {
		display: flex;
		gap: 0.4em;
		flex-wrap: wrap;
		margin-bottom: 1.2em;
	}

	.format-toggles button {
		background: #333;
		border: none;
		color: #ccc;
		padding: 0.4em 0.9em;
		cursor: pointer;
		border-radius: 4px;
		font-size: 0.95em;
	}

	.format-toggles button:hover {
		background: #444;
	}

	.format-toggles button.active {
		background: #555;
		color: #fff;
	}

	.field {
		margin-bottom: 1em;
	}

	.label {
		display: block;
		margin-bottom: 0.4em;
		opacity: 0.6;
		font-size: 0.9em;
	}

	.tool-row {
		display: flex;
		align-items: center;
		gap: 0.8em;
		flex-wrap: wrap;
	}

	.toggles {
		display: flex;
		gap: 0.4em;
	}

	.toggles button {
		background: #333;
		border: none;
		color: #ccc;
		padding: 0.3em 0.8em;
		cursor: pointer;
		border-radius: 4px;
		font-size: 0.9em;
	}

	.toggles button:hover {
		background: #444;
	}

	.toggles button.active {
		background: #555;
		color: #fff;
	}

	.install-link {
		font-size: 0.8em;
		opacity: 0.5;
	}

	.install-link:hover {
		opacity: 0.8;
	}

	.command-row {
		display: flex;
		gap: 0.6em;
		align-items: flex-start;
	}

	pre {
		flex: 1;
		background: #080808;
		padding: 0.8em;
		border-radius: 4px;
		overflow-x: auto;
		margin: 0;
		font-size: 0.85em;
	}

	code {
		white-space: pre;
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
	}

	.copy-btn:hover {
		background: #444;
	}
</style>
