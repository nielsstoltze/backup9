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
echo "[install-tools] done"
