#!/bin/bash
# Carve out an 800 GB LV in ubuntu-vg and build an encrypted ZFS pool 'backup'
# on it. The pool is created with a *passphrase* keyformat so we can later
# swap in the app81 key-fetch chain without recreating the pool.
#
# Idempotent: skips create steps if the artefact already exists.
set -euo pipefail
log() { echo "[install-zfs] $*"; }

VG="ubuntu-vg"
LV="zfs"
LV_SIZE="825G"
POOL="backup"
KEYFILE="/etc/zfs/backup.key.initial"   # used only on first create; rotated
                                         # to app81-fetch by install-key-fetch.sh

# 1. Create LV
if sudo lvs "$VG/$LV" &>/dev/null; then
    log "LV $VG/$LV already exists"
else
    log "creating LV $VG/$LV ($LV_SIZE)"
    sudo lvcreate -n "$LV" -L "$LV_SIZE" "$VG"
fi

# 2. Create pool
if sudo zpool list "$POOL" &>/dev/null; then
    log "pool '$POOL' already imported"
else
    log "generating initial encryption key at $KEYFILE"
    sudo mkdir -p /etc/zfs
    sudo chmod 700 /etc/zfs
    # keyformat=raw expects exactly 32 raw bytes; don't base64-encode
    sudo install -m 600 /dev/stdin "$KEYFILE" < <(head -c 32 /dev/urandom)

    log "creating pool '$POOL' on /dev/$VG/$LV with native encryption"
    sudo zpool create \
        -o ashift=12 \
        -O encryption=aes-256-gcm \
        -O keyformat=raw \
        -O keylocation="file://$KEYFILE" \
        -O compression=lz4 \
        -O atime=off \
        -O xattr=sa \
        -O acltype=posixacl \
        -O mountpoint=/mnt/backup \
        "$POOL" "/dev/$VG/$LV"
fi

# 3. Datasets — one per FREJA share so we can snapshot/retention each
#    independently and report per-share size.
SHARES=(Backup Birgitte Scanned Stoltze TC Yvonne)
sudo zfs list -H -o name "$POOL/freja" &>/dev/null \
    || sudo zfs create "$POOL/freja"
for s in "${SHARES[@]}"; do
    if sudo zfs list -H -o name "$POOL/freja/$s" &>/dev/null; then
        log "dataset $POOL/freja/$s exists"
    else
        log "creating dataset $POOL/freja/$s"
        sudo zfs create "$POOL/freja/$s"
    fi
done

# 4. Permissions — the orchestrator runs as root for cifs mount, but we keep
#    the dataset roots owned by root:root with 0755 so anything readable in
#    the backup is auditable but not world-writable.
sudo chown -R root:root /mnt/backup
sudo find /mnt/backup -type d -exec chmod 0755 {} +

log "DONE — pool=$POOL  size_logical=$(zfs list -H -o avail "$POOL")"
