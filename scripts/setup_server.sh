#SECRET="???"

RED='\033[0;31m'
NC='\033[0m'

set -e
set -x

echo -e "${RED}SETUP SYSTEM${NC}"
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - # for node js
apt-get -qq -y update
apt-get -qq -y upgrade
apt-get -qq -y install curl git libnginx-mod-http-brotli-filter libnginx-mod-http-brotli-static nginx supervisor ufw webhook
ufw allow OpenSSH
ufw allow 8080/tcp
ufw allow 9000/tcp
ufw --force enable
git config --global --add safe.directory '*'

echo -e "${RED}ADD USER${NC}"
mkdir /var/www/data
chown www-data /var/www/
su - www-data -s /bin/bash
cd /var/www/
git clone https://github.com/versatiles-org/tiles.versatiles.org.git
exit

echo -e "${RED}ADD MAP DATA${NC}"
wget "https://download.versatiles.org/planet-latest.versatiles" -O /var/www/data/osm.versatiles

echo -e "${RED}ADD FRONTEND${NC}"
wget -q "https://github.com/versatiles-org/versatiles-frontend/releases/latest/download/frontend.br.tar" -O /var/www/data/frontend.br.tar

echo -e "${RED}ADD VERSATILES${NC}"
curl -sL "https://github.com/versatiles-org/versatiles-rs/releases/latest/download/versatiles-linux-gnu-aarch64.tar.gz" | gzip -d | tar -xOf - versatiles > /usr/local/bin/versatiles
chown root:root /usr/local/bin/versatiles
chmod +x /usr/local/bin/versatiles

echo -e "${RED}CONFIG VERSATILES${NC}"
ln -s /var/www/tiles.versatiles.org/config/supervisor/versatiles.conf /etc/supervisor/conf.d/versatiles.conf
supervisorctl reload

echo -e "${RED}CONFIG NGINX${NC}"
mkdir /etc/nginx/sites
mkdir /var/www/logs
rm -r /etc/nginx/sites-available
rm -r /etc/nginx/sites-enabled
rm /etc/nginx/nginx.conf
ln -s /var/www/tiles.versatiles.org/config/nginx/nginx.conf /etc/nginx/nginx.conf
ln -s /var/www/tiles.versatiles.org/config/nginx/tiles.versatiles.org.conf /etc/nginx/sites/tiles.versatiles.org.conf
nginx -s reload

echo -e "${RED}CONFIG WEBHOOK${NC}"
ln -s /var/www/tiles.versatiles.org/config/supervisor/webhooks.conf /etc/supervisor/conf.d/webhooks.conf
cat /var/www/tiles.versatiles.org/config/webhook/webhook.yaml | sed "s/%SECRET%/$SECRET/g" > /var/www/webhook.yaml
supervisorctl reload

# reboot
