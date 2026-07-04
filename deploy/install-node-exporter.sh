#!/usr/bin/env bash
# Install prometheus-node-exporter on backup9 for JUPITER scraping
# (backlog: 'Tilfoej backup9 til JUPITER scrape-targets + systemd-failed
# alert'). Enables the systemd collector so JUPITER owns the
# systemd_unit_state time-series for backup-run@*/zfs-unlock-backup --
# long-term replacement for the interim OnFailure= Telegram path.
#
# Idempotent; run as root. Ubuntu 26.04 note: avoid `install -g` /
# `install /dev/stdin` (rust-coreutils traps) -- use tee + chmod.
set -euo pipefail

JUPITER_IP="100.67.4.96"

echo "== 1/4 apt install =="
export DEBIAN_FRONTEND=noninteractive
apt-get install -y prometheus-node-exporter >/dev/null
echo "   installed: $(dpkg-query -W -f='${Version}' prometheus-node-exporter)"

echo "== 2/4 enable systemd collector =="
tee /etc/default/prometheus-node-exporter >/dev/null <<'EOF'
# Managed by backup9 repo (deploy/install-node-exporter.sh).
# --collector.systemd => node_systemd_unit_state for backup-run@* etc.
ARGS="--collector.systemd"
EOF
systemctl enable --now prometheus-node-exporter
systemctl restart prometheus-node-exporter

echo "== 3/4 ufw allow from JUPITER (${JUPITER_IP}) =="
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow from "${JUPITER_IP}" to any port 9100 proto tcp \
      comment "JUPITER prometheus scrape" >/dev/null
  echo "   ufw rule ensured"
else
  echo "   ufw not active -- skipped"
fi

echo "== 4/4 verify =="
sleep 2
if curl -s --max-time 5 http://127.0.0.1:9100/metrics | grep -q '^node_systemd_unit_state'; then
  echo "   OK: node_exporter up, systemd collector active"
else
  echo "   FAIL: no node_systemd_unit_state in /metrics" >&2
  exit 1
fi
