#!/usr/bin/env bash
set -euo pipefail

# Rolls out a new nginx image, and nothing else. Runs daily from cron (see
# setup_auto_update.sh), so that a security fix in nginx — which reaches the
# official image the day nginx releases it — is live within a day instead of
# waiting for the next ./bin/update.sh.
#
# Unlike update.sh this touches nothing but the nginx container: no git pull,
# no tile data, no cache clear. And since it runs unattended, it only acts when
# it is safe to:
#   - It does nothing if no newer image arrived under the same tag, or if
#     compose.yaml describes nginx differently from the running container (that
#     change belongs to ./bin/update.sh).
#   - Before the switch, the repository's nginx config must load in the new
#     image (tests/nginx-config.sh, the same check CI runs). If it doesn't,
#     the running nginx is left alone.
#   - The switch costs about 3 seconds of refused connections (recreate_nginx).
#   - If the new container doesn't become healthy, nginx is recreated from the
#     previous image.
#
# Exits 0 when nginx is up to date or was updated, 1 when something needs a
# look — see /var/log/nginx-update.log.

cd "$(dirname "$0")/../.."
source bin/deploy/helpers.sh

log() { echo "$(date -u +%FT%TZ) $*"; }

acquire_deploy_lock

if ! service_is_running nginx; then
    log "Error: nginx is not running. Not starting it unattended — run ./bin/update.sh."
    exit 1
fi

cid=$(docker compose ps -q nginx | head -n 1)

# The running container must match compose.yaml (same hash compose stored when
# it created the container). Otherwise a recreate would also roll out that
# definition change, without update.sh's other steps.
want_hash=$(docker compose config --hash nginx | awk '{print $2}')
have_hash=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.config-hash" }}' "$cid")
if [ "$want_hash" != "$have_hash" ]; then
    log "Error: compose.yaml describes nginx differently from the running container. Run ./bin/update.sh."
    exit 1
fi

image_ref=$(docker inspect -f '{{.Config.Image}}' "$cid")
old_image=$(docker inspect -f '{{.Image}}' "$cid")

docker compose pull --quiet nginx
new_image=$(docker image inspect -f '{{.Id}}' "$image_ref")

if [ "$new_image" = "$old_image" ]; then
    log "nginx is up to date ($image_ref)."
    exit 0
fi
log "A new $image_ref arrived: ${old_image:7:12} → ${new_image:7:12}."

# Point the tag back at the image nginx runs, so that nothing (this script, or
# update.sh) picks up a new image that was not rolled out.
restore_old_tag() { docker tag "$old_image" "$image_ref"; }

if ! ./tests/nginx-config.sh; then
    restore_old_tag
    log "Error: the nginx config does not load in the new image. nginx keeps running the previous one."
    log "       Fix the config before the next ./bin/update.sh, which would roll the new image out."
    exit 1
fi

# In a subshell: recreate_nginx exits through wait_for_healthy when the new
# container does not become healthy, and the rollback below must still run.
if ! (recreate_nginx); then
    log "Error: the new nginx did not become healthy. Rolling back to the previous image."
    restore_old_tag
    recreate_nginx
    exit 1
fi

log "nginx now runs the new image. Verifying..."
./bin/verify.sh
log "nginx update completed."
