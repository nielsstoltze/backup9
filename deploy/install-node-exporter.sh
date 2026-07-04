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
# NB: with the systemd collector /metrics is BIG -- a short curl timeout cuts
# the stream mid-family (exporter logs 'write: connection reset by peer') and
# the grep false-FAILs. Check the collector's own success gauge instead.
if curl -s --max-time 30 http://127.0.0.1:9100/metrics \
     | grep -q 'node_scrape_collector_success{collector="systemd"} 1'; then
  echo "   OK: node_exporter up, systemd collector active"
else
  echo "   FAIL: systemd collector not reporting success" >&2
  exit 1
fi
