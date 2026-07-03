# Lab-host pulls (lab-app81 / lab-chost11)

Closes the gap found 2026-07-03: backup9 only covered FREJA (Windows) shares,
while all Linux-host state lived unbacked. Code is on GitHub (37 repos on
app81 alone), so these jobs pull only what a rebuild CANNOT recover from git:

| Host | Staged (by infra/scripts/backup-stage.sh, cron 04:30) |
|---|---|
| app81 | `~/secrets/` (64 env/CA files), sqlite DBs (apollo, comms, links, loganalyzer, vlan-cleanup), crontab, systemd user units, Claude memory + settings, git-repo manifest (repo -> HEAD) |
| chost11 | docker compose/.env files + `backups/` (nightly pg dumps of Nautobot + Authentik), AdGuard conf, nginx-tls conf, `~/.acme.sh` (wildcard cert + LE account), `~/bin`, crontab, git manifest |

## How it works

1. **04:30 on each host** — `backup-stage.sh` assembles `~/backup-stage/`
   (consistent sqlite copies via python's backup API; rsync for dirs;
   root-unreadable files are listed in `MANIFEST.txt` instead of failing).
2. **05:15 / 05:45 on backup9** — `backup-run lab-app81|lab-chost11`
   (`type: ssh` jobs): rsync-over-ssh pull into `backup/lab/<host>`,
   ZFS snapshot, state file, Telegram on failure — identical flow to the
   FREJA jobs, minus the CIFS mount.
3. **Retention** — sanoid `template_lab`: 30 daily / 12 weekly / 6 monthly.

## SSH key

Pulls authenticate with the dedicated key `/root/.ssh/backup_pull_ed25519`
(backup-run's systemd unit runs as root). The public key is installed on
app81 + chost11 in `~local_admin/.ssh/authorized_keys` restricted with:

```
from="192.168.150.9",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA... backup9-pull
```

Network path: backup9 (home-bis LAN) -> S2S tunnel -> lab; verified
`:22` reachable to both hosts 2026-07-03.

## Restore notes

- Everything under `/mnt/backup/lab/<host>/` mirrors the host's
  `~/backup-stage/`; snapshots give history (`zfs list -t snapshot`).
- app81 rebuild: clone repos per `system/git-manifest.txt`, restore
  `secrets/` -> `~/secrets/`, sqlite files back into their repo dirs,
  `system/systemd-user/` -> `~/.config/systemd/user/` + `systemctl --user
  daemon-reload`, `system/crontab.txt` -> `crontab`.
- chost11 rebuild: compose/.env back under `~/docker/`, restore pg dumps
  (`gunzip -c ... | docker exec -i <db> psql -U <user> <db>`), acme dir back,
  then `docker compose up -d` per stack.
