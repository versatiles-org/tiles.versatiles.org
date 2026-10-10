#!/usr/bin/env bash
set -euo pipefail

# Makes sure the RAM disk for the nginx cache exists, is mounted at
# volumes/cache, has the size set by RAM_DISK_GB in .env, and comes back after a
# reboot (an entry in /etc/fstab).
#
# Safe to run again at any time — bin/deploy/ensure.sh does so on every update.
# Each run brings three things in line:
#
#   1. /etc/fstab   The entry for this checkout is added, or rewritten when
#                   RAM_DISK_GB changed. Entries for the RAM disk of a checkout
#                   that no longer exists are removed: when the repository is
#                   moved, the old entry would otherwise mount an empty RAM
#                   disk at the old path on every boot, forever.
#   2. the mount    Mounted if it is not.
#   3. the size     If it is mounted with a different size than RAM_DISK_GB,
#                   it is resized in place — the cached files stay.
#
# nginx limits its cache to 90% of RAM_DISK_GB (see
# nginx/docker-entrypoint.d/10-compute-cache-size.envsh). If the RAM disk did
# not follow a raised RAM_DISK_GB, nginx would fill it up and fail to write.

# Navigate to the root directory of the project relative to the script location.
cd "$(dirname "$0")/../.."

# Load environment variables from the .env file
source .env

FSTAB=/etc/fstab

# Validate RAM_DISK_GB before touching anything.
if ! [[ "${RAM_DISK_GB:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: RAM_DISK_GB is not set or not a positive whole number (\"${RAM_DISK_GB:-}\")."
    exit 1
fi

# Create the cache directory if it doesn't already exist.
mkdir -p volumes/cache

CACHE_PATH="$(pwd)/volumes/cache"
WANTED_ENTRY="ramdisk ${CACHE_PATH}/ tmpfs defaults,size=${RAM_DISK_GB}G,x-gvfs-show 0 0"

# -----------------------------------------------------------------------------
# 1. /etc/fstab
# -----------------------------------------------------------------------------
# Go through fstab line by line and build the new content. A line is "one of
# ours" when it mounts a tmpfs named `ramdisk` at a path ending in
# /volumes/cache — the form this script writes.
[ -f "$FSTAB" ] || touch "$FSTAB"

NEW_CONTENT=""
FOUND=false
CHANGED=false
while IFS= read -r line || [ -n "$line" ]; do
    source_name="" mount_point="" fs_type=""
    read -r source_name mount_point fs_type _ <<<"$line" || true

    if [ "$source_name" = "ramdisk" ] && [ "$fs_type" = "tmpfs" ] && [[ "$mount_point" =~ /volumes/cache/?$ ]]; then
        if [ "${mount_point%/}" = "$CACHE_PATH" ]; then
            # The entry for this checkout.
            if [ "$FOUND" = "true" ]; then
                echo "Removing duplicate RAM disk entry from $FSTAB."
                CHANGED=true
                continue
            fi
            FOUND=true
            if [ "$line" != "$WANTED_ENTRY" ]; then
                echo "Updating the RAM disk entry in $FSTAB:"
                echo "  old: $line"
                echo "  new: $WANTED_ENTRY"
                line="$WANTED_ENTRY"
                CHANGED=true
            fi
        elif [ ! -d "${mount_point%/}" ]; then
            # The RAM disk of a checkout that is gone.
            echo "Removing a stale RAM disk entry from $FSTAB (its directory no longer exists):"
            echo "  $line"
            CHANGED=true
            continue
        else
            # Another path that still exists: possibly a second installation,
            # possibly a leftover. Not ours to decide.
            echo "NOTE: $FSTAB has a RAM disk entry for another path that still exists:"
            echo "        $line"
            echo "      If that is a leftover of an earlier installation, unmount it, delete the"
            echo "      line from $FSTAB, and remove the directory."
        fi
    fi
    NEW_CONTENT+="$line"$'\n'
done <"$FSTAB"

if [ "$FOUND" = "false" ]; then
    echo "Adding the RAM disk entry to $FSTAB."
    NEW_CONTENT+="$WANTED_ENTRY"$'\n'
    CHANGED=true
fi

if [ "$CHANGED" = "true" ]; then
    cp "$FSTAB" "$FSTAB.bak"
    # Write through the existing file (not a rename), so its owner and
    # permissions stay as they are.
    printf '%s' "$NEW_CONTENT" >"$FSTAB"
    echo "$FSTAB updated (previous version saved as $FSTAB.bak)."

    # systemd derives mount units from fstab and needs to be told.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
    fi
fi

# -----------------------------------------------------------------------------
# 2. Mount
# -----------------------------------------------------------------------------
if ! mountpoint -q "$CACHE_PATH"; then
    echo "Mounting the RAM disk (${RAM_DISK_GB}G) at $CACHE_PATH..."
    mount "$CACHE_PATH"
    echo "RAM disk configured and mounted successfully."
    exit 0
fi

# -----------------------------------------------------------------------------
# 3. Size
# -----------------------------------------------------------------------------
WANTED_BYTES=$((RAM_DISK_GB * 1024 * 1024 * 1024))
CURRENT_BYTES=$(findmnt --bytes --noheadings --output SIZE --target "$CACHE_PATH" 2>/dev/null | tr -d ' ' || echo "")

if [ -z "$CURRENT_BYTES" ]; then
    echo "RAM disk is already mounted (could not read its size to compare with RAM_DISK_GB)."
elif [ "$CURRENT_BYTES" = "$WANTED_BYTES" ]; then
    echo "RAM disk is already mounted."
else
    echo "RAM disk is mounted with $((CURRENT_BYTES / 1024 / 1024 / 1024))G, but RAM_DISK_GB is ${RAM_DISK_GB} — resizing it in place."
    if mount -o "remount,size=${RAM_DISK_GB}G" "$CACHE_PATH"; then
        echo "RAM disk resized to ${RAM_DISK_GB}G."
    else
        echo "Error: could not resize the RAM disk to ${RAM_DISK_GB}G."
        echo "       When shrinking, it must not hold more data than the new size."
        echo "       Empty the cache with ./bin/ramdisk/clear.sh and run this script again."
        exit 1
    fi
fi
