# tiles.versatiles.org

Production setup for serving VersaTiles map tiles with nginx reverse proxy, SSL via Let's Encrypt, and RAM disk caching.

## Features

- **Caching**: RAM disk cache for fast tile serving
- **SSL**: Automatic Let's Encrypt certificates with OCSP stapling
- **Security**: Rate limiting, anonymized logging, no-new-privileges containers
- **Health checks**: Container health monitoring for versatiles and nginx

## Install

Install dependencies (Debian/Ubuntu):
```bash
apt-get update && apt-get -y upgrade
apt-get -y install git wget ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update && apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
shutdown -r now
```

Clone and initialize:
```bash
git clone https://github.com/versatiles-org/tiles.versatiles.org.git
cd tiles.versatiles.org
cp template.env .env
nano .env  # Set DOMAIN_NAME, EMAIL, RAM_DISK_GB
./bin/init.sh
```

## Update

```bash
./bin/update.sh
```

## Configuration

Edit `.env` to configure:
- `DOMAIN_NAME` - Your domain (e.g., tiles.versatiles.org)
- `EMAIL` - Email for Let's Encrypt notifications
- `RAM_DISK_GB` - RAM disk size for caching
- `BBOX` - Optional bounding box to download only a region
