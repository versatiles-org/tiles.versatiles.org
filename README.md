# Repository Overview

This repository contains all the necessary components to serve files from [download.versatiles.org](https://download.versatiles.org). It includes configuration files, webhooks, and a simple HTML template for displaying file listings. Contributors are welcome to improve the file listing by modifying [`html/template.html`](https://github.com/versatiles-org/download.versatiles.org/blob/main/html/template.html).

## Repository Structure

Below is an overview of the repository's folder structure and contents:

- **`config`**: Contains configuration files for Nginx and the webhook.
  - **`config/nginx`**: Includes Nginx configuration with special rules for `index.html`, `robots.txt`, and `favicon.ico`.
  - **`config/webhook`**: Houses the webhook configuration. It triggers `pull.sh` upon activation. `webhook.yaml` uses a placeholder "%SECRET%" that is replaced with the actual secret by `scripts/setup_server.sh`.
- **`html`**: Holds the script for generating `index.html` from `template.html`.
  - **`html/docs`**: The directory that will be served by Nginx.
- **`script`**: Contains helper scripts, including the server setup script.

## Administration

### Preparation

Before setting up the server, ensure you have the necessary tools installed:

```bash
brew install hcloud # MacOS
hcloud context create versatile # Use hcloud for administrating Hetzner Cloud
```

### Setting Up the Server

To create the server, execute the setup script:

```bash
./create_server.sh
```

### Updating

Updates are managed automatically using webhooks.

### Deleting the Server

When no longer needed, the server can be removed with:

```bash
./delete_server.sh
```
