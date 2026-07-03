#!/bin/bash
# Install the tools backup9 needs to do its job.
set -euo pipefail

PKGS=(
    zfsutils-linux       # ZFS
    sanoid               # snapshot retention (zfs-auto-snapshot replacement)
    cifs-utils           # mount -t cifs for the FREJA pull
    smbclient            # ad-hoc SMB probe
    rsync                # the actual file transport
    python3-venv         # status API
    python3-yaml         # jobs.yaml parser
    git                  # for keeping /opt/backup9 in sync with the repo
    jq                   # job-orchestrator JSON munging
)
sudo apt-get update
sudo apt-get install -y --no-install-recommends "${PKGS[@]}"

# FREJA is mounted by its bare hostname (//freja/<share>), but backup9 sits on
# the home-bis network whose DNS does not serve the hoej.eu zone -- so neither
# `freja` nor `freja.hoej.eu` resolves here. Pin it in /etc/hosts so the CIFS
# pull works and, crucially, SURVIVES a rebuild (this bit us: a rebuild lost
# the entry and every backup failed silently for ~18 days). Idempotent.
FREJA_IP=192.168.101.33
if ! grep -qE "[[:space:]]freja([[:space:]]|$)" /etc/hosts; then
    echo "$FREJA_IP  freja freja.hoej.eu" | sudo tee -a /etc/hosts >/dev/null
    echo "[install-tools] pinned freja -> $FREJA_IP in /etc/hosts"
fi
echo "[install-tools] done"
