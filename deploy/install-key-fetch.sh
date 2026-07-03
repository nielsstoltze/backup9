#!/bin/bash
# Wire up the boot-time key fetch from app81.
#
# Pre-reqs:
#   * pool 'backup' already created with an initial keyfile (install-zfs.sh)
#   * app81 reachable from backup9 over the S2S tunnel
#   * APP81_HOST has a backup9-fetch user with a forced-command authorized_keys
#     entry (this script tells you how to set that up on the app81 side, but
#     does not do it for you — that part lives in nielsstoltze/infra later).
#
# Idempotent.
set -euo pipefail
log() { echo "[install-key-fetch] $*"; }

POOL="backup"
APP81_USER="backup9-fetch"
APP81_HOST="100.67.4.81"

# 1. SSH keypair (no passphrase — root systemd needs to use it headlessly)
KEYPATH=/root/.ssh/id_ed25519_app81-fetch
sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh
if [[ -f "$KEYPATH" ]]; then
    log "SSH key already exists at $KEYPATH"
else
    log "generating SSH key at $KEYPATH"
    sudo ssh-keygen -t ed25519 -N "" -C "backup9-fetch@backup9" -f "$KEYPATH"
fi

# 2. Trust the app81 host key (one-shot scan to known_hosts so the systemd
#    unit doesn't trip StrictHostKeyChecking on boot)
sudo touch /root/.ssh/known_hosts
sudo chmod 600 /root/.ssh/known_hosts
if ! sudo grep -q "^$APP81_HOST " /root/.ssh/known_hosts; then
    log "scanning $APP81_HOST host key into /root/.ssh/known_hosts"
    sudo ssh-keyscan -t ed25519 "$APP81_HOST" 2>/dev/null \
        | sudo tee -a /root/.ssh/known_hosts >/dev/null
fi

# 3. Install the fetch helper + the systemd unit
sudo install -m 0755 \
    /opt/backup9/usr-local-sbin/zfs-fetch-and-unlock \
    /usr/local/sbin/zfs-fetch-and-unlock
sudo install -m 0644 \
    /opt/backup9/systemd/zfs-unlock-backup.service \
    /etc/systemd/system/zfs-unlock-backup.service
sudo systemctl daemon-reload
sudo systemctl enable zfs-unlock-backup.service

cat <<EOF

================================================================
  Next step (run on app81, NOT here):
  --------------------------------------------------------------
  1. Create the dedicated user:
       sudo useradd -r -m -s /usr/sbin/nologin -d /var/lib/backup9-fetch backup9-fetch
       sudo mkdir -p /var/lib/backup9-fetch/.ssh
       sudo chmod 700 /var/lib/backup9-fetch/.ssh

  2. Put the encryption key alongside it:
       sudo install -m 600 -o backup9-fetch -g backup9-fetch \\
            <(head -c 32 /dev/urandom) /var/lib/backup9-fetch/backup.key

  3. Authorize this pubkey with a forced command:
       echo 'command="cat /var/lib/backup9-fetch/backup.key",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,restrict $(sudo cat $KEYPATH.pub)' \\
            | sudo tee -a /var/lib/backup9-fetch/.ssh/authorized_keys
       sudo chown backup9-fetch:backup9-fetch /var/lib/backup9-fetch/.ssh/authorized_keys
       sudo chmod 600 /var/lib/backup9-fetch/.ssh/authorized_keys

  4. (Last) Rotate the ZFS key on backup9 from the local initial key to the
     fetched-from-app81 key:
       sudo zfs change-key -L file:///run/zfs-keys/$POOL.key $POOL
     after running /usr/local/sbin/zfs-fetch-and-unlock $POOL manually once.
================================================================
EOF
