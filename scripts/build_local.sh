#!/bin/bash
set -e
cd "$(dirname $0)/.."

docker build --progress=plain -t versatiles-nginx .
