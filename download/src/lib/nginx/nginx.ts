/**
 * Utilities for generating the final NGINX configuration used by
 * download.versatiles.org.
 *
 * The configuration is produced from a template literal and populated with:
 * - `localFiles`: files served from local storage (alias)
 * - `remoteFiles`: files served via WebDAV proxy
 * - `responses`: virtual inline responses such as checksum files or URL lists
 * - `webdavAuth`: Base64-encoded credentials for WebDAV proxy
 * - `webdavHost`: WebDAV server hostname
 */
import { writeFileSync, renameSync } from 'fs';
import { FileRef } from '../file/file_ref.js';
import { FileResponse } from '../file/file_response.js';

/**
 * Builds the full NGINX configuration as a string.
 */
export function buildNginxConf(files: FileRef[], responses: FileResponse[]): string {
	const domain = process.env['DOMAIN'];

	// Parse STORAGE_URL to get WebDAV host and user
	const storageUrl = process.env['STORAGE_URL'] ?? '';
	const storagePass = process.env['STORAGE_PASS'] ?? '';

	let webdavHost = '';
	let webdavAuth = '';

	if (storageUrl && storagePass) {
		// STORAGE_URL format: user@host
		const match = storageUrl.match(/^([^@]+)@(.+)$/);
		if (match) {
			const [, user, host] = match;
			webdavHost = host;
			// Create Base64-encoded Basic Auth header
			webdavAuth = Buffer.from(`${user}:${storagePass}`).toString('base64');
		}
	}

	// Separate local and remote files
	const localFiles = files.filter((f) => !f.isRemote);
	const remoteFiles = files.filter((f) => f.isRemote);

	// Sort for deterministic output
	localFiles.sort((a, b) => a.url.localeCompare(b.url));
	remoteFiles.sort((a, b) => a.url.localeCompare(b.url));
	responses.sort((a, b) => a.url.localeCompare(b.url));

	const localFileBlocks = localFiles.map((f) => `    location = ${f.url} { alias ${f.fullname}; }`).join('\n');

	const remoteFileBlocks = remoteFiles
		.map(
			(f) => `    location = ${f.url} {
        proxy_pass https://${webdavHost}${f.webdavPath};
        proxy_set_header Host ${webdavHost};
        proxy_set_header Authorization "Basic ${webdavAuth}";
        proxy_ssl_server_name on;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
    }`,
		)
		.join('\n');

	const responseBlocks = responses.map((r) => `    location = ${r.url} { return 200 "${r.content}"; }`).join('\n');

	return `server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

limit_conn_zone \$binary_remote_addr zone=download_addr:10m;

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name ${domain};
    server_tokens off;

    ssl_certificate /etc/nginx/ssl/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/live/${domain}/privkey.pem;
    ssl_trusted_certificate /etc/nginx/ssl/live/${domain}/chain.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'EECDH+AESGCM:EDH+AESGCM';
    ssl_session_cache shared:SSL_DOWNLOAD:10m;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    limit_conn download_addr 8;
    limit_rate 50m;

    root /volumes/content;

    types {
        text/plain md5 sha256 tsv txt;
        text/html html;
        text/css css;
        application/javascript js;
        application/octet-stream versatiles;
        application/rss+xml xml;
    }

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        sendfile           on;
        sendfile_max_chunk 1m;
    }

    # Local files (served from disk)
${localFileBlocks}

    # Remote files (proxied via WebDAV)
${remoteFileBlocks}

    # Responses (inline content)
${responseBlocks}

    location = /robots.txt {
        default_type text/plain;
        return 200 "User-agent: *\\nAllow: /\\n";
    }

    location = / {
        try_files \$uri \$uri/ /index.html;
    }
}
`;
}

/**
 * Generates the NGINX configuration and writes it to disk atomically.
 * Uses temp file + rename to prevent partial writes.
 */
export function generateNginxConf(files: FileRef[], responses: FileResponse[], filename: string) {
	console.log('Generating NGINX configuration...');
	const tempFile = filename + '.tmp';
	writeFileSync(tempFile, buildNginxConf(files, responses));
	renameSync(tempFile, filename);
	console.log(' - Configuration successfully written');
}
