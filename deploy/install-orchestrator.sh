#!/bin/bash
# Install the orchestrator helper + per-job timer drop-ins from jobs.yaml.
# Idempotent.
set -euo pipefail
log() { echo "[install-orch] $*"; }

REPO_ROOT="${REPO_ROOT:-/opt/backup9}"

# 1. orchestrator binary
sudo install -m 0755 \
    "$REPO_ROOT/usr-local-sbin/backup-run" \
    /usr/local/sbin/backup-run

# 2. directories — readable by local_admin (the status-api runs as that user)
sudo mkdir -p /etc/backup9 /var/lib/backup9/state /var/log/backup9
sudo chgrp local_admin /etc/backup9 /var/lib/backup9 /var/lib/backup9/state
sudo chmod 0750 /etc/backup9 /var/lib/backup9 /var/lib/backup9/state /var/log/backup9

# 3. jobs.yaml — only copy if not already locally edited
if [[ -f /etc/backup9/jobs.yaml ]]; then
    log "/etc/backup9/jobs.yaml exists — leaving alone (refresh by hand if needed)"
else
    sudo install -m 0640 "$REPO_ROOT/etc/jobs.yaml" /etc/backup9/jobs.yaml
fi

# 4. service + timer templates
sudo install -m 0644 "$REPO_ROOT/systemd/backup-run@.service" /etc/systemd/system/
sudo install -m 0644 "$REPO_ROOT/systemd/backup-run@.timer" /etc/systemd/system/

# 5. sanoid config
sudo install -m 0644 "$REPO_ROOT/etc/sanoid.conf" /etc/sanoid/sanoid.conf
sudo systemctl enable --now sanoid.timer

# 6. per-job timer overrides (so we don't ship one timer per job)
sudo systemctl daemon-reload
JOBS=$(python3 -c "
import yaml
for j in yaml.safe_load(open('$REPO_ROOT/etc/jobs.yaml'))['jobs']:
    print(j['name'] + ' ' + j['schedule'])
")
while read -r name schedule; do
    [[ -z "$name" ]] && continue
    DROPIN="/etc/systemd/system/backup-run@${name}.timer.d"
    sudo mkdir -p "$DROPIN"
    sudo install -m 0644 /dev/stdin "$DROPIN/schedule.conf" <<EOF
[Timer]
OnCalendar=
OnCalendar=$schedule
EOF
    sudo systemctl enable --now "backup-run@${name}.timer"
    log "enabled timer for $name -> $schedule"
done <<< "$JOBS"

log "DONE — list timers with: systemctl list-timers backup-run@*"
