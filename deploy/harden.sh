#!/bin/bash
# backup9 post-install hardening. Idempotent — re-runnable.
#
# Notes:
#   - UFW is intentionally NOT enabled here; perimeter FW is PAN-OS-managed.
#   - dpkg-divert for /etc/profile.d/80-systemd-osc-context.sh is generic to
#     all Ubuntu 26.04+ hosts; promote to ~/infra/roles/ when we have a 2nd
#     26.04 box that needs it.
set -euo pipefail

log() { echo "[harden] $*"; }

# 1. systemd OSC 3008 — disable, terminal-emulators that don't grok it
#    (e.g. SecureCRT 9.x) render the escapes as text. dpkg-divert survives
#    package upgrades.
OSC=/etc/profile.d/80-systemd-osc-context.sh
if [[ -e "$OSC" ]]; then
    log "diverting $OSC"
    sudo dpkg-divert --local --rename --add "$OSC"
else
    log "$OSC already diverted (or missing — first-run state)"
fi

# 2. SSH hardening — disable password root login, keep PasswordAuthentication
#    on for the time being (backup-user uses pw for SFTP). Will tighten when
#    we move that off pw too.
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-backup9-harden.conf
sudo install -m 644 /dev/stdin "$SSHD_DROPIN" <<'EOF'
# Managed by backup9/deploy/harden.sh — do not edit by hand.
PermitRootLogin no
PermitEmptyPasswords no
X11Forwarding no
ClientAliveInterval 60
ClientAliveCountMax 3
MaxAuthTries 4
LoginGraceTime 30
EOF
sudo systemctl reload ssh || sudo systemctl reload sshd || true
log "wrote $SSHD_DROPIN + reloaded sshd"

# 3. sysctl baseline — modest network + kernel safety. No knee-jerk
#    locks that would break SMB pulls.
SYSCTL=/etc/sysctl.d/99-backup9.conf
sudo install -m 644 /dev/stdin "$SYSCTL" <<'EOF'
# Managed by backup9/deploy/harden.sh
net.ipv4.tcp_syncookies            = 1
net.ipv4.conf.all.rp_filter        = 1
net.ipv4.conf.default.rp_filter    = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects   = 0
net.ipv4.conf.all.log_martians     = 1
kernel.dmesg_restrict              = 1
kernel.kptr_restrict               = 2
EOF
sudo sysctl --system >/dev/null
log "applied $SYSCTL"

# 4. fail2ban — pw-protected SFTP user means brute-force is in scope.
sudo apt-get install -y --no-install-recommends fail2ban >/dev/null
sudo systemctl enable --now fail2ban
log "fail2ban running ($(systemctl is-active fail2ban))"

# 5. Unattended security upgrades — pure-backup-box, low blast-radius if
#    a security update lands and reboots us.
sudo apt-get install -y --no-install-recommends unattended-upgrades >/dev/null
sudo dpkg-reconfigure -f noninteractive unattended-upgrades
log "unattended-upgrades enabled"

log "DONE"
