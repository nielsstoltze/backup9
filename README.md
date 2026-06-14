# backup9

Offsite backup server — pull-based, JARVIS-monitored.

## Hardware

- Physical box at 192.168.150.9 (home-bis network)
- 1× Samsung 870 SSD 932 GB
- 14 GiB RAM, Intel i5-6400T
- Ubuntu Server 26.04 LTS

## Architecture

```
┌── FREJA (//freja/<share>, 192.168.101.33) ──┐
│   Backup  Birgitte  Scanned  Stoltze  TC  Yvonne
└──────────────────┬──────────────────────────┘
                   │ cifs ro pull
                   ▼
┌── backup9 ──────────────────────────────────┐
│  /etc/backup9/jobs.yaml      SoT             │
│  /usr/local/sbin/backup-run  orchestrator    │
│  systemd backup-run@<job>.timer  scheduled   │
│  zfs pool 'backup' (encrypted, lz4)          │
│    └─ backup/freja/<share>  one dataset each │
│  sanoid                      30d/12w/12m     │
│  FastAPI :8094               status API      │
│  Telegram HOEJ-AUTO          fail alerts     │
└──────────────────┬──────────────────────────┘
                   │ ssh on boot
                   ▼
┌── app81 (100.67.4.81) ──────────────────────┐
│  user: backup9-fetch                         │
│  forced command: cat .../backup.key          │
│  → returns 32B raw ZFS encryption key        │
└──────────────────────────────────────────────┘
```

Why this shape:
- **Pull** so JARVIS controls schedule + retention + alerting centrally.
- **ZFS encrypted** so a stolen box has no readable data.
- **Key fetched from app81** so the key never lives on backup9's disk.
- **sanoid** for retention (we don't roll our own snapshot pruning).
- **One dataset per FREJA share** for independent retention / per-share size.

## First install

Order matters:

```bash
# 1. clone this repo onto backup9
git clone https://github.com/nielsstoltze/backup9 /opt/backup9
sudo ln -s /opt/backup9 /opt/backup9-current  # symlink for upgrade later

# 2. apply hardening (incl. dpkg-divert for OSC 3008)
sudo /opt/backup9/deploy/harden.sh

# 3. install tools + ZFS pool
sudo /opt/backup9/deploy/install-tools.sh
sudo /opt/backup9/deploy/install-zfs.sh

# 4. (optional but recommended) move to app81-fetched encryption key
sudo /opt/backup9/deploy/install-key-fetch.sh
# follow the printed app81-side instructions, then:
sudo /usr/local/sbin/zfs-fetch-and-unlock backup
sudo zfs change-key -L file:///run/zfs-keys/backup.key backup

# 5. orchestrator + timers
sudo /opt/backup9/deploy/install-orchestrator.sh

# 6. status API
cd /opt/backup9/status-api
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
sudo install -m 0644 /opt/backup9/systemd/backup-status.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now backup-status

# 7. drop FREJA creds in:
sudo install -m 0600 /dev/stdin /etc/backup9/secrets.env <<EOF
FREJA_USER=backup
FREJA_PASS=…from ~/secrets/backup9-sftp.env on app81…
EOF
```

## Day-to-day

- `systemctl list-timers 'backup-run@*'` — when is the next run
- `journalctl -u backup-run@freja-Backup` — what happened
- `curl https://backup9.hoej.eu:8094/api/jobs` — last-run state per job
- `zfs list -t snapshot -r backup` — what we can roll back to
- `zfs rollback backup/freja/Stoltze@auto-2026-…` — restore

## See also

- `docs/recovery.md` — restoring a single file or whole dataset
- `docs/sanoid-retention.md` — why 30d/12w/12m
- `docs/key-rotation.md` — how to swap the app81-side key
