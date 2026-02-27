<script lang="ts">
	import type { PageData } from './$types.js';

	let { data }: { data: PageData } = $props();
</script>

<svelte:head>
	<meta charset="utf-8" />
	<title>VersaTiles - Download</title>
	<meta name="viewport" content="width=device-width" />
	<meta name="description" content="Download VersaTiles map data — OpenStreetMap, hillshading, landcover, bathymetry, and satellite imagery as .versatiles containers." />
	<meta property="og:title" content="VersaTiles Downloads" />
	<meta property="og:description" content="Download VersaTiles map data — OpenStreetMap, hillshading, landcover, bathymetry, and satellite imagery as .versatiles containers." />
	<meta property="og:type" content="website" />

	<link
		rel="shortcut icon"
		sizes="16x16 24x24 32x32 48x48 64x64"
		href="https://versatiles.org/assets/logo/favicon.ico"
	/>
	<link rel="icon" type="image/png" href="https://versatiles.org/assets/logo/versatiles.32.png" sizes="32x32" />
	<link rel="icon" type="image/png" href="https://versatiles.org/assets/logo/versatiles.48.png" sizes="48x48" />
	<link rel="icon" type="image/png" href="https://versatiles.org/assets/logo/versatiles.64.png" sizes="64x64" />
	<link rel="icon" type="image/png" href="https://versatiles.org/assets/logo/versatiles.96.png" sizes="96x96" />

	{#each data.fileGroups as group}
		{#if group.olderFiles.length > 0}
			<link
				rel="alternate"
				type="application/rss+xml"
				title="Versatiles data releases: {group.slug}"
				href="/feed-{group.slug}.xml"
			/>
		{/if}
	{/each}
</svelte:head>

<main>
	<div style="width: min(50rem, 90%); margin: auto">
		<p style="text-align: center; margin: 0">
			<img width="25%" src="https://versatiles.org/assets/logo/versatiles.svg" alt="VersaTiles logo" />
		</p>
		<h1><a href="https://versatiles.org/">VersaTiles</a> Downloads</h1>
		<header class="small">
			<p>
				All files are
				<a href="https://github.com/versatiles-org/versatiles-spec/blob/main/v02/readme.md">VersaTiles v02 containers</a
				>. Please use this download service only to download these files.
			</p>
		</header>

		{#each data.fileGroups as group}
			<h2>{group.title}</h2>
			<dd class="small">
				{@html group.desc}
				<p class="group-links small">
					<a href="/urllist_{group.slug}.tsv">URL list</a>
					<a href="/feed-{group.slug}.xml">RSS</a>
				</p>
			</dd>

			{#if group.latestFile}
				<a class="row" href={group.latestFile.url} title={group.latestFile.filename}>
					<span>{group.latestFile.filename}</span>
					<span>{group.latestFile.sizeString}</span>
				</a>
			{/if}
			{#if group.olderFiles.length > 0}
				<details>
					<summary class="small">Show all versions</summary>
					{#each group.olderFiles as file}
						<div class="row">
							<a href={file.url}>{file.filename}</a>
							<a href="{file.url}.md5" class="small">md5</a>
							<a href="{file.url}.sha256" class="small">sha256</a>
							<a href={file.url}>{file.sizeString}</a>
						</div>
					{/each}
				</details>
			{/if}
		{/each}
	</div>
</main>

<footer>
	<a href="https://github.com/versatiles-org/tiles.versatiles.org/blob/main/download/src/routes/+page.svelte"
		>Improve this page on GitHub</a
	>
</footer>

<style>
	:global(body) {
		background: #080808;
		color: #ccc;
		margin: 0;
		padding: 0;
		font-family: system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
		font-weight: 500;
		font-size: min(1.2rem, 5vmin);
		line-height: 1.3;
		color-scheme: dark;
	}

	:global(a) {
		color: #eee;
		text-decoration: none;
	}

	:global(a:hover) {
		text-decoration: underline;
	}

	main {
		padding: 1rem 0 5rem;
		overflow-x: hidden;
	}

	summary,
	.small {
		opacity: 0.5;
		font-size: 0.8em;
	}

	summary,
	header,
	dd {
		margin: 1em 0;
		text-align: center;
	}

	dd,
	header,
	h1,
	h2 {
		text-align: center;
		font-weight: normal;
	}

	h2 {
		margin: 5em 0 0.5em;
	}

	.row {
		margin: 0 auto;
		padding: 0.1em max(0px, calc(50% - 250px));
		display: flex;
		justify-content: space-between;
		background-color: #111;
		text-decoration: none;
		align-items: center;
	}

	.row:hover {
		background-color: #333;
		text-decoration: none;
	}

	.row .small {
		opacity: 0.4;
		font-size: 0.8em;
		font-weight: normal;
	}

	.group-links {
		text-align: center;
		margin-top: 0.5em;
		display: flex;
		justify-content: center;
		gap: 1.5em;
	}

	footer {
		margin: 10em 0 0;
		text-align: right;
		opacity: 0.4;
		font-size: 0.8em;
		padding: 0.5em;
	}
</style>
