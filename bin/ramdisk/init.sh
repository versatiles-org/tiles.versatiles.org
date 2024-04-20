#!/usr/bin/env bash
cd $(dirname "$0")/../..
. .env

mkdir -p volumes/cache
echo "ramdisk $(pwd)/volumes/cache/ tmpfs defaults,size=${RAM_DISK_GB}G,x-gvfs-show 0 0" >> /etc/fstab
systemctl daemon-reload
mount volumes/cache
