#!/bin/bash
# One-shot: rotate the 'backup' pool key from the local initial keyfile
# (/etc/zfs/backup.key.initial) to the app81-fetched key.
#
# Runs on backup9 as root.  Pool MUST already be created + key loaded
# (install-zfs.sh handles that on first install).
#
# After this runs, the pool can ONLY be unlocked by re-fetching from
# app81 — the initial keyfile is shredded.
set -euo pipefail

POOL=backup
APP81_HOST=100.67.4.81
APP81_USER=local_admin
SSH_KEY=/root/.ssh/id_ed25519_app81-fetch
KEY_DIR=/run/zfs-keys
KEY_PATH="$KEY_DIR/$POOL.key"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
mountpoint -q "$KEY_DIR" || mount -t tmpfs -o size=1M,mode=0700 tmpfs "$KEY_DIR"

ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes \
    "$APP81_USER@$APP81_HOST" "$POOL" > "$KEY_PATH"
chmod 600 "$KEY_PATH"

KEY_BYTES=$(wc -c < "$KEY_PATH")
echo "fetched key bytes: $KEY_BYTES"
[[ "$KEY_BYTES" -eq 32 ]] || { echo "ERROR: key not 32 bytes"; exit 2; }

echo "running: zfs change-key -o keylocation=file://$KEY_PATH $POOL"
zfs change-key -o keylocation="file://$KEY_PATH" "$POOL"

echo "new keylocation: $(zfs get -H -o value keylocation $POOL)"

if [[ -f /etc/zfs/backup.key.initial ]]; then
    shred -u -n 1 /etc/zfs/backup.key.initial
    echo "initial keyfile shredded"
fi

echo "DONE — pool now uses app81-fetched key"
