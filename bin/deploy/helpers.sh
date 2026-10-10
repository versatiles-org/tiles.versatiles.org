#!/usr/bin/env bash
# Shared helper functions for deploy scripts. Source this file, don't execute it.

# Make sure only one of update.sh / restart.sh / serve-mode.sh runs at a time.
# They all rewrite versatiles.yaml, replace containers and clear the cache; two
# of them interleaving (a second terminal, a cron job) leaves the server in a
# state neither intended.
#
# The lock is an flock on a file, held through file descriptor 9 for as long as
# the calling script runs. It is released by the kernel when the script exits —
# however it exits — so there is no stale lock to clean up.
#
# Call it from the repository root, before doing anything that changes state.
acquire_deploy_lock() {
	local lock_file="volumes/.deploy.lock"
	if ! command -v flock >/dev/null 2>&1; then
		# Not on the server (flock is part of util-linux there) — e.g. a
		# developer's macOS machine. Nothing to protect.
		return 0
	fi
	mkdir -p volumes
	exec 9>"$lock_file"
	if ! flock --nonblock 9; then
		echo "Error: another update, restart or serve-mode run is in progress (lock: $lock_file)." >&2
		echo "       Wait for it to finish, then try again." >&2
		exit 1
	fi
}

wait_for_healthy() {
	local service="$1"
	local timeout="${2:-120}"
	local elapsed=0
	echo "Waiting for $service to be healthy..."
	while [ $elapsed -lt "$timeout" ]; do
		if docker compose ps --format json "$service" 2>/dev/null | grep -q '"healthy"'; then
			echo "$service is healthy."
			return 0
		fi
		sleep 2
		elapsed=$((elapsed + 2))
	done
	echo "Error: $service did not become healthy within ${timeout}s"
	exit 1
}

# True when the running container of a service no longer matches what
# compose.yaml describes — a different image tag, changed mounts/env/logging, or
# a newer image pulled under the same tag. Such a change only takes effect once
# the container is replaced. False when the service has no container.
service_has_pending_change() {
	local service="$1" cid want_hash have_hash image want_image have_image
	cid=$(docker compose ps -q "$service" 2>/dev/null | head -n 1)
	[ -n "$cid" ] || return 1

	# Compose definition: the hash compose stores on every container it creates.
	want_hash=$(docker compose config --hash "$service" | awk '{print $2}')
	have_hash=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.config-hash" }}' "$cid")
	[ "$want_hash" = "$have_hash" ] || return 0

	# Same definition, but `docker compose pull` may have fetched a newer image
	# under the same tag.
	image=$(docker inspect -f '{{.Config.Image}}' "$cid")
	want_image=$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || echo "")
	have_image=$(docker inspect -f '{{.Image}}' "$cid")
	[ -n "$want_image" ] && [ "$want_image" != "$have_image" ]
}

# Replace the tile server container with a fresh one, with (almost) no failed
# requests: the new container is started next to the old one, and the old one is
# only stopped once the new one is healthy.
#
# Why not `docker compose up --force-recreate`: that stops the old container
# first, and the tile server needs a few seconds to load the frontend and open
# its tile sources. Measured at ~100 req/s: about 4 seconds of 502 for every URL
# that is not in the nginx cache, against 0–5 failed requests with this
# procedure.
#
# It relies on two things in nginx/templates/proxy.conf.template:
#   - the upstream follows Docker's DNS (`server versatiles:8080 resolve`), so
#     nginx starts using the new container and drops the old one on its own —
#     no reload needed;
#   - `proxy_connect_timeout 1s`, so a request that still hits the old
#     container's address the moment it disappears fails over quickly.
#
# A side benefit: if the new container never becomes healthy (broken image, bad
# config), it is removed again and the old one keeps serving.
#
# The fresh container reads everything a tile server reads at startup: the
# image, versatiles.yaml and the frontend/styles tars.
replace_tile_server() {
	local old new id count=0 elapsed=0 timeout=180 health

	old=$(docker compose ps -q versatiles 2>/dev/null || echo "")
	if [ -z "$old" ]; then
		echo "Tile server is not running — starting it."
		docker compose up --detach versatiles
		wait_for_healthy versatiles
		return 0
	fi
	for id in $old; do count=$((count + 1)); done

	# The swap is only gap-free if nginx follows Docker's DNS. A running nginx
	# that still has an older rendered config (upstream address fixed at config
	# load) would keep sending requests to the old container's address after it
	# is gone. Bring its config up to date first.
	if service_is_running nginx && ! docker compose exec -T nginx grep -q 'server versatiles:8080 resolve' /etc/nginx/conf.d/proxy.conf; then
		echo "nginx does not follow the tile server's address yet — applying the current nginx config first."
		nginx_render_and_reload
		sleep 2
	fi

	echo "Starting a new tile server container next to the running one..."
	docker compose up --detach --no-deps --no-recreate --scale "versatiles=$((count + 1))" versatiles

	new=""
	for id in $(docker compose ps -q versatiles); do
		case " $(echo "$old" | tr '\n' ' ') " in
			*" $id "*) ;;
			*) new="$id" ;;
		esac
	done
	if [ -z "$new" ]; then
		echo "Error: no new tile server container was created."
		return 1
	fi

	echo "Waiting for the new tile server to be healthy..."
	while [ "$elapsed" -lt "$timeout" ]; do
		health=$(docker inspect -f '{{.State.Health.Status}}' "$new" 2>/dev/null || echo "gone")
		[ "$health" = "healthy" ] && break
		sleep 2
		elapsed=$((elapsed + 2))
	done
	if [ "$health" != "healthy" ]; then
		echo "Error: the new tile server did not become healthy within ${timeout}s (status: $health)."
		echo "       Its last log lines:"
		docker logs --tail 20 "$new" 2>&1 | sed 's/^/         /'
		echo "       Removing it; the old tile server keeps serving."
		docker rm --force "$new" >/dev/null
		return 1
	fi

	# nginx marks an upstream address as failed for 10s (fail_timeout) after an
	# error, and the new address may have been tried while it was still
	# starting. Stopping the old container inside that window would leave nginx
	# with no usable upstream for a moment.
	echo "New tile server is healthy — waiting 12s before retiring the old one..."
	sleep 12

	for id in $old; do
		docker stop "$id" >/dev/null
		docker rm "$id" >/dev/null
	done
	echo "Tile server replaced."
}

# Make the tile server pick up a change, in the cheapest way that works.
#
# Usage: apply_tile_server <mode>
#   sighup   The change is in versatiles.yaml only: SIGHUP makes versatiles
#            reload it in place (tile sources updated incrementally, in-flight
#            requests complete). But if the container itself is out of date
#            (see service_has_pending_change), it is replaced instead — the new
#            container reads the new versatiles.yaml as well.
#   replace  Always replace the container. Needed for what versatiles reads only
#            at startup, above all the frontend/styles tars: their `static:`
#            paths are the same before and after a release, so a SIGHUP reload
#            sees nothing to do.
apply_tile_server() {
	local mode="$1"
	case "$mode" in
		sighup|replace) ;;
		*) echo "Error: unknown mode '$mode' (expected: sighup|replace)"; return 1 ;;
	esac

	if ! service_is_running versatiles; then
		replace_tile_server   # starts it
	elif [ "$mode" = "replace" ]; then
		replace_tile_server
	elif service_has_pending_change versatiles; then
		echo "Tile server container is out of date (new image or changed compose definition)."
		replace_tile_server
	else
		echo "Sending SIGHUP to the tile server to reload versatiles.yaml."
		docker compose kill -s SIGHUP versatiles
	fi
}

# Bring a service up so it reflects current compose state, then make sure it
# re-reads any mounted config files even if compose state was unchanged.
#
# Used for nginx. The tile server goes through apply_tile_server() instead,
# which replaces the container without a gap.
#
# `docker compose up --detach SERVICE` already recreates the container when
# the image, environment, or mount definitions have changed. But the contents
# of files inside a mounted volume (e.g. versatiles.yaml) are
# invisible to compose — when only file *content* changes, `up` is a no-op
# and the running container keeps using the stale config it read at startup.
#
# This helper detects whether `up` actually recreated the container (by
# comparing container IDs) and runs an extra fallback action if it didn't.
#
# Usage:
#   up_with_config_fallback <service> <fallback>
#   <fallback> ∈ { sighup, reload, restart }
#     sighup  → `docker compose kill -s SIGHUP SERVICE` (versatiles reloads its
#               -c config with no downtime: tile sources updated incrementally,
#               in-flight requests complete against the version they started with)
#     reload  → `docker compose exec SERVICE nginx -s reload` (graceful reload)
#     restart → `docker compose restart SERVICE`         (full restart, drops
#               in-flight connections — last resort)
up_with_config_fallback() {
	local service="$1"
	local fallback="$2"

	local before after
	before=$(docker compose ps -q "$service" 2>/dev/null || echo "")
	# --timeout 3: if this recreates the container, do not wait Docker's default
	# 10s for the old one to stop (see recreate_nginx).
	docker compose up --detach --timeout 3 "$service"
	after=$(docker compose ps -q "$service" 2>/dev/null || echo "")

	if [ -z "$before" ] || [ "$before" != "$after" ]; then
		# Container was started or recreated — it already reads the latest config.
		echo "$service container recreated (compose state changed)."
		return 0
	fi

	# Container was unchanged at the compose level; force it to pick up new
	# file content from mounted volumes.
	case "$fallback" in
		sighup)
			echo "$service compose state unchanged — sending SIGHUP to reload config."
			docker compose kill -s SIGHUP "$service"
			;;
		reload)
			echo "$service compose state unchanged — re-rendering templates and reloading."
			nginx_render_and_reload
			;;
		restart)
			echo "$service compose state unchanged — restarting to re-read config."
			docker compose restart "$service"
			;;
		*)
			echo "Error: unknown fallback action '$fallback' (expected: sighup|reload|restart)"
			exit 1
			;;
	esac
}

# True when the named compose service has a running container.
#
# `docker compose ps -q` alone is not enough: across compose versions it has both
# included and excluded stopped containers, so the container state is checked
# explicitly.
service_is_running() {
	local cid
	cid=$(docker compose ps -q "$1" 2>/dev/null || echo "")

	[ -n "$cid" ] && [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo false)" = "true" ]
}

# Re-render nginx's config templates inside the running container and reload.
#
# nginx renders /etc/nginx/templates/*.template into /etc/nginx/conf.d only once,
# at container startup (entrypoint: 10-compute-cache-size sets CACHE_MAX_SIZE_MB,
# then the image's 20-envsubst renders). A plain `nginx -s reload` re-reads the
# already-rendered conf, so edits to the *template* stay invisible until the
# container is recreated — hence re-running the render steps here, sourcing the
# cache-size envsh first so CACHE_MAX_SIZE_MB is defined.
#
# The reload itself is graceful: the master keeps serving through old workers
# until the new ones are up, so no connection is dropped. Requires a running
# nginx container.
#
# `nginx -t` runs between rendering and reloading: `nginx -s reload` only signals
# the master and exits 0 even when the new config is invalid (nginx then keeps
# running the old one), so without the test a broken template would go unnoticed
# here.
#
# The reload also applies changes to nginx/nginx.conf: the container reads it
# through the directory mount at /etc/nginx/repo (see nginx/nginx.stub.conf).
# The cache-size script is sourced from that directory mount as well, because
# its copy in /docker-entrypoint.d is a single-file mount that still shows the
# file as it was when the container started. A container created before that
# directory mount existed only has the copy in /docker-entrypoint.d.
nginx_render_and_reload() {
	docker compose exec -T nginx sh -c '
		envsh=/etc/nginx/repo/docker-entrypoint.d/10-compute-cache-size.envsh
		[ -f "$envsh" ] || envsh=/docker-entrypoint.d/10-compute-cache-size.envsh
		. "$envsh"
		/docker-entrypoint.d/20-envsubst-on-templates.sh && nginx -t && nginx -s reload'
}

# Recreate the nginx container from the image and definition in compose.yaml.
# Needed for a new nginx image or a changed definition (ports, mounts, env,
# logging, …); a reload cannot apply those.
#
# This is the one operation that cannot be done without a gap: only one
# container can hold the host's ports 80/443, and nginx stops accepting
# connections the moment it is told to stop. New connections are refused until
# the replacement listens — about 3 seconds.
#
#   --no-deps   do not let compose touch the tile server as nginx's dependency;
#               it is replaced separately, without a gap (replace_tile_server).
#   --force-recreate   the caller has decided; this also covers a newer image
#               under an unchanged tag.
#   --timeout 3   how long the *old* container may take to stop. Compose would
#               otherwise use the timeout the old container was created with —
#               not the stop_grace_period now in compose.yaml — which for a
#               container from before that setting is Docker's default of 10s.
recreate_nginx() {
	echo "Recreating the nginx container — new connections are refused for a few seconds."
	docker compose up --detach --no-deps --force-recreate --timeout 3 nginx
	wait_for_healthy nginx
}

# Apply nginx config changes without risking a container recreate.
#
# up_with_config_fallback() leads with `docker compose up --detach`, which
# recreates the container whenever compose-level state changed — most often a
# base image that `docker compose pull` just fetched. Recreating nginx unbinds
# :80/:443 for a moment: in-flight connections are dropped and new ones refused
# until the replacement is listening. That is an acceptable price on the tile
# update path, which is already reloading services; it is not one to pay on a
# run where nothing else happened and only the config needs applying.
#
# So reload in place instead. A pulled nginx image is simply left for the next
# run that goes through the full update path.
#
# If nginx is not running there is nothing to reload in place, so hand over to
# up_with_config_fallback, which starts it — and, through compose's depends_on,
# starts versatiles first if that is down too.
#
# If nginx is running but versatiles is not, the reload is skipped instead. nginx
# resolves `server versatiles:8080` at config-load time, so with the container
# gone the reload fails with `[emerg] host not found in upstream` and a non-zero
# exit, which under `set -e` would abort the caller before it reaches its own
# verification step. Nothing is lost by skipping: the running nginx keeps serving
# its current config, and a config change cannot be applied while the upstream is
# missing either way.
reload_nginx_in_place() {
	if ! service_is_running nginx; then
		echo "nginx is not running — bringing it up instead of reloading."
		up_with_config_fallback nginx reload
		return
	fi

	if ! service_is_running versatiles; then
		echo "Warning: versatiles is not running — skipping the nginx reload."
		echo "         nginx would fail to load a config naming an upstream it cannot"
		echo "         resolve. The running nginx keeps serving its current config."
		return 0
	fi

	echo "Re-rendering nginx templates and reloading in place."
	nginx_render_and_reload
}
