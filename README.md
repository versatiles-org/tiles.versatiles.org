# tiles.versatiles.org


## Install

Update the system, install git, wget and docker-compose, and reboot:
```bash
apt update
apt -ys upgrade
apt -ys install git wget ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt -ys install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
shutdown -r now
````

```bash
git clone https://github.com/versatiles-org/tiles.versatiles.org.git
cd tiles.versatiles.org
./init.sh
```


## 
