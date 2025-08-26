# n8n Backup & Restore – User Guide

Simple, reliable backups and restores for an **n8n (Docker)** stack—with optional Google Drive uploads and email notifications.

---

## Table of Contents

- [What this script does](#what-this-script-does)
- [Folder basics](#folder-basics)
- [Requirements (one‑time)](#requirements-one-time)
- [Email notifications (optional but recommended)](#email-notifications-optional-but-recommended)
- [Google Drive uploads (optional)](#google-drive-uploads-optional)
- [Quick start (most common)](#quick-start-most-common)
- [Command options (cheat‑sheet)](#command-options-cheat-sheet)
- [What to expect after a backup](#what-to-expect-after-a-backup)
- [How change detection works](#how-change-detection-works)
- [Restore (step by step)](#restore-step-by-step)
- [Scheduling (automatic daily backups)](#scheduling-automatic-daily-backups)
- [Google Drive path tips](#google-drive-path-tips)
- [Where to check logs](#where-to-check-logs)
- [Common examples](#common-examples)
- [Troubleshooting & FAQs](#troubleshooting--faqs)
- [Safety notes](#safety-notes)
- [Support](#support)

---
## What this script does

- Backs up Docker **volumes**: `n8n-data`, `postgres-data`, `letsencrypt`
- Creates a **PostgreSQL dump** (from the `postgres` container, DB `n8n`)
- Saves copies of your `` and ``
- **Skips** backup automatically if nothing has changed (unless you force it)
- Keeps a rolling **30‑day summary** in `backups/backup_summary.md`
- Optionally **uploads** backups to **Google Drive** via `rclone`
- Sends **email alerts** through Gmail SMTP (**msmtp**) — with the log file attached on failures (and optionally on success)

---

## Folder basics

Run the script from your n8n project folder (the one that contains your `docker-compose.yml` and `.env`):

```
/your/project/
├── docker-compose.yml
├── .env
├── n8n_backup_restore.sh
├── backups/           # created automatically (archives + summary + snapshot)
└── logs/              # created automatically (run logs)
```

---

## Requirements (one‑time)

- **Install the tools the script needs (Ubuntu/Debian)**

```bash
sudo apt-get update
sudo apt-get install -y docker.io rsync tar msmtp-mta rclone dnsutils curl openssl
```

> `getopt` (from util‑linux) is usually already present on Ubuntu.\
> Docker must be running, and your n8n stack should be up via `docker compose`.

- **Check your `.env` file contains `N8N_ENCRYPTION_KEY`**  
  n8n uses an encryption key to protect stored credentials. This key is critical for **backup and restore**.  

  - If you already set `N8N_ENCRYPTION_KEY` in your `.env`, you’re good.  
  - If not, n8n auto-generated one inside the main container on first run.  

Retrieve it with:  
```bash
docker exec -it $(docker ps --format '{{.Names}}' | grep -E '^n8n($|-)' | head -n 1) \
cat /home/node/.n8n/config | grep -oP '(?<="encryptionKey": ")[^"]+'
```

This will print the raw key, for example:
```bash
oZ+XKX2XpGuOgBLj+YyaOlcS8JgKkkE
```

- **Copy this into your .env file so it is persistent:**
```bash
N8N_ENCRYPTION_KEY=oZ+XKX2XpGuOgBLj+YyaOlcS8JgKkkE
```

---

## Email notifications (optional but recommended)

The script uses **Gmail via msmtp**. Set two environment variables before running:

```bash
export SMTP_USER="youraddress@gmail.com"
export SMTP_PASS="your_app_password"   # Use a Gmail App Password (see below)
```

- **Gmail App Password:**\
  In your Google Account → Security → 2‑Step Verification → **App passwords** → create one (choose “Mail”, device “Other”).\
  Paste that 16-character password into `SMTP_PASS`.

- Where do emails go? Pass a recipient with `-e you@example.com`.

---

## Google Drive uploads (optional)

1. Configure `rclone` once:

```bash
rclone config      # create a remote, e.g., name it: gdrive-user
```

During `rclone config`, pick **Google Drive**, authorize, and finish.

2. Choose your target folder name in Drive (e.g., `n8n-backups`).\
   The script will upload into that folder under the remote you select.

You’ll pass these when running:

- `-s gdrive-user` (remote name)

> Tip: Verify the path with `rclone lsd gdrive-user:` and `rclone ls gdrive-user:n8n-backups`.

---

## Quick start (most common)

### 1) Command options (cheat‑sheet)

| Option       | Long form                | Meaning                                                |
| ------------ | ------------------------ | ------------------------------------------------------ |
| `-b`         | `--backup`               | Run a backup (only if changes detected).               |
| `-f`         | `--force`                | Force the backup (ignore change detection).            |
| `-r <FILE>`  | `--restore <FILE>`       | Restore from a backup archive (`.tar.gz`).             |
| `-d <DIR>`   | `--dir <DIR>`            | Base directory of your n8n project (default: /home/n8n). |
| `-l <LEVEL>` | `--log-level <LEVEL>` | `DEBUG` (verbose), `INFO` (default), `WARN` (non-fatal issues), `ERROR` (only fatal). |
| `-e <EMAIL>` | `--email <EMAIL>`        | Email recipient for notifications.                     |
| `-s <NAME>`  | `--remote-name <NAME>`   | `rclone` remote (e.g., `gdrive-user`).                 |
| `-n`         | `--notify-on-success`    | Also email on success (not just on failures).          |
| `-h`         | `--help`                 | Show help.                                             |

**Environment vars used:** `SMTP_USER`, `SMTP_PASS` (for Gmail auth).

### 2) Backup scenarios

**Use case 01: Execute the backup at local, not upload, no email notification:**
```bash
./n8n_backup_restore.sh -b
```
On success, you will see the following logs:
```bash
	═════════════════════════════════════════════════════════════
	Action:                 Backup (normal)
	Status:                 SUCCESS
	Timestamp:              2025-08-16_15-18-00
	Domain:                 https://n8n-test.nguyenminhthe.com
	Backup file:            /home/n8n/backups/n8n_backup_1.106.3_2025-08-16_15-18-00.tar.gz
	N8N Version:            1.106.3
	Log File:               /home/n8n/logs/backup_n8n_2025-08-16_15-18-00.log
	Daily tracking:         /home/n8n/backups/backup_summary.md
	Google Drive upload:    SKIPPED
	Email notification:     SKIPPED (not requested)
	═════════════════════════════════════════════════════════════
```

If no change is detected, the backup process will be skipped; use -f to force backup.
```bash
	═════════════════════════════════════════════════════════════
	Action:                 Skipped
	Status:                 SKIPPED
	Timestamp:              2025-08-16_15-20-34
	Domain:                 https://n8n-test.nguyenminhthe.com
	N8N Version:            1.106.3
	Log File:               /home/n8n/logs/backup_n8n_2025-08-16_15-20-34.log
	Daily tracking:         /home/n8n/backups/backup_summary.md
	Google Drive upload:    SKIPPED
	Email notification:     SKIPPED (not requested)
	═════════════════════════════════════════════════════════════
```

**Use case 02: Execute the backup at local, upload to Google Drive, no email notification:**

- Execute the backup (skip if nothing changed), upload to Google Drive:
```bash
./n8n_backup_restore.sh -b -s gdrive-user
```

- On backup success, you’ll see:
```bash
	═════════════════════════════════════════════════════════════
	Action:                 Backup (normal)
	Status:                 SUCCESS
	Timestamp:              2025-08-16_15-28-02
	Domain:                 https://n8n-test.nguyenminhthe.com
	Backup file:            /home/n8n/backups/n8n_backup_1.106.3_2025-08-16_15-28-02.tar.gz
	N8N Version:            1.106.3
	Log File:               /home/n8n/logs/backup_n8n_2025-08-16_15-28-02.log
	Daily tracking:         /home/n8n/backups/backup_summary.md
	Google Drive upload:    SUCCESS
	Email notification:     SKIPPED (not requested)
	═════════════════════════════════════════════════════════════
```

**Use case 03: Execute the backup at local, upload to Google Drive, send email on failure:**

- Execute the backup (force even if no change), upload to Google Drive, and send the email on failure of backup/upload:
```bash
./n8n_backup_restore.sh -b -s gdrive-user -e you@YourDomain.com
```
- On backup success, you’ll see:
```bash
	═════════════════════════════════════════════════════════════
	Action:                 Backup (forced)
	Status:                 SUCCESS
	Timestamp:              2025-08-16_15-28-02
	Domain:                 https://n8n-test.nguyenminhthe.com
	Backup file:            /home/n8n/backups/n8n_backup_1.106.3_2025-08-16_15-28-02.tar.gz
	N8N Version:            1.106.3
	Log File:               /home/n8n/logs/backup_n8n_2025-08-16_15-28-02.log
	Daily tracking:         /home/n8n/backups/backup_summary.md
	Google Drive upload:    FAILED
	Email notification:     SUCCESS
	═════════════════════════════════════════════════════════════
```

**Use case 04: Execute the backup at local, upload to Google Drive, always send email:**

```bash
./n8n_backup_restore.sh -b -s gdrive-user -e you@YourDomain.com --notify-on-success
```

- On backup success, you’ll see:
```bash
	═════════════════════════════════════════════════════════════
	Action:                 Backup (forced)
	Status:                 SUCCESS
	Timestamp:              2025-08-16_15-28-02
	Domain:                 https://n8n-test.nguyenminhthe.com
	Backup file:            /home/n8n/backups/n8n_backup_1.106.3_2025-08-16_15-28-02.tar.gz
	N8N Version:            1.106.3
	Log File:               /home/n8n/logs/backup_n8n_2025-08-16_15-28-02.log
	Daily tracking:         /home/n8n/backups/backup_summary.md
	Google Drive upload:    SUCCESS
	Email notification:     SUCCESS
	═════════════════════════════════════════════════════════════
```

- You can check the daily backup status:
  
```bash
cat /root/n8n-main/backups/backup_summary.md
| DATE               | ACTION         | N8N_VERSION | STATUS   |
|--------------------|----------------|-------------|----------|
| 2025-08-13_02-00-00 | Backup (normal) | 1.107.0 | SUCCESS |
| 2025-08-14_02-00-00 | Backup (normal) | 1.107.0 | SUCCESS |
| 2025-08-15_02-00-00 | Backup (normal) | 1.107.0 | SUCCESS |
| 2025-08-16_02-00-00 | Skipped | 1.107.0 | SKIPPED |
| 2025-08-17_02-00-00 | Skipped | 1.107.0 | SKIPPED |
| 2025-08-18_02-00-00 | Skipped | 1.107.0 | SKIPPED |
| 2025-08-19_02-00-00 | Skipped | 1.107.0 | SKIPPED |
| 2025-08-20_02-00-00 | Backup (forced) | 1.107.0 | SUCCESS |
```

**Use case 05: Backup existing n8n installation in the specified directory**

If your existing n8n was installed in the specified directory (not default as /home/n8n):

```bash
./n8n_backup_restore.sh -b -d /path/to/n8n -s gdrive-user -e you@YourDomain.com
```

## What to expect after a backup

- **Backup files:** in `backups/`, named like\
  `n8n_backup_<N8N_VERSION>_<YYYY-MM-DD_HH-MM-SS>.tar.gz`
- **Summary file:** `backups/backup_summary.md` tracks daily history (last 30 days kept)
- **Logs:** `logs/backup_n8n_<timestamp>.log`
- **Change detection snapshot:** `backups/snapshot/` (internal use)

A final console summary shows:

- Action taken (Backup normal/forced, or Skipped)
- Timestamp
- Domain (from `.env`)
- Archive path
- n8n version
- Whether upload to Google Drive succeeded/skipped/failed
- Whether an email was sent

---

## How change detection works

To avoid unnecessary backups, the script compares your live data with a **snapshot** stored in `backups/snapshot/`.\
It looks for differences in:

- Volumes: `n8n-data`, `postgres-data`, `letsencrypt`\
  (Excludes churny Postgres dirs like `pg_wal`, `pg_stat_tmp`, `pg_logical`)
- Config files: `.env`, `docker-compose.yml`

If nothing changed since the last successful backup, it **skips** (unless you use `-f`).

> After each successful backup, the snapshot is refreshed automatically.

Example logs:
```bash
═════════════════════════════════════════════════════════════
Action:               Skipped
Timestamp:            2025-08-14_00-46-17
Domain:               https://n8n.YourDomain.com
N8N Version:          1.107.0
Log File:             /root/n8n-main/logs/backup_n8n_2025-08-14_00-46-17.log
Daily tracking:       /root/n8n-main/backups/backup_summary.md
Google Drive upload:  SKIPPED
Email notification:   SKIPPED
═════════════════════════════════════════════════════════════
```
---

## Restore (step by step)

**Warning:** Restore will **stop containers** and **replace volumes** with data from the archive.

- Restore with the tar.gz file at local:

```bash
./n8n_backup_restore.sh -r backups/your_backup_file.tar.gz

```
Example logs:
```bash
═════════════════════════════════════════════════════════════
Restore completed successfully.
Domain:               https://n8n-test.nguyenminhthe.com
Restore from file:    /home/n8n/backups/n8n_backup_1.106.3_2025-08-16_15-55-00.tar.gz
Local archive used:   /home/n8n/backups/n8n_backup_1.106.3_2025-08-16_15-55-00.tar.gz
N8N Version:          1.105.3
N8N Directory:        /home/n8n/
Log File:             /root/n8n-main/logs/restore_n8n_2025-08-13_16-39-54.log
Timestamp:            2025-08-13_16-39-54
Volumes Restored:     n8n-data, postgres-data, letsencrypt
PostgreSQL:           Restored from SQL dump
═════════════════════════════════════════════════════════════
```

- Restore from a Google Drive remote path (via rclone):

```bash
./n8n_backup_restore.sh -r gdrive-user:n8n_backup_1.107.2_2025-08-18_01-10-30.tar.gz
```
Example logs:
```bash
═════════════════════════════════════════════════════════════
Restore completed successfully.
Domain:               https://n8n-test.nguyenminhthe.com
Restore from file:    gdrive-user:n8n_backup_1.107.2_2025-08-18_01-10-30.tar.gz
Local archive used:   /home/n8n/backups/_restore_tmp/gdrive-user_n8n_backup_1.107.2_2025-08-18_01-10-30.tar.gz
N8N Version:          1.107.2
N8N Directory:        /home/n8n
Log File:             /home/n8n/logs/restore_n8n_2025-08-18_01-12-49.log
Timestamp:            2025-08-18_01-12-49
Volumes restored:     n8n-data, letsencrypt
PostgreSQL:           Restored from SQL dump
═════════════════════════════════════════════════════════════
```
---

What it does:

- Stops current stack (`docker compose down --volumes --remove-orphans`)
- Removes volumes `n8n-data`, `postgres-data`, `letsencrypt`
- Restores volume archives and the saved `.env` / `docker-compose.yml` (if present)
- Brings the stack back up
- If it finds a SQL dump file, it:
  - Drops and recreates the `database`, and restores it

> ⚠️ Make sure your `.env` database name matches the one you restore into.\
> This script restores the dump into ``. If your app uses `DB_POSTGRESDB=n8n`, either update `.env` to `n8ndb` or adjust the script/restore step accordingly.

On restore success, you’ll see:
  ```bash
═════════════════════════════════════════════════════════════
Restore completed successfully.
Domain:               https://n8n-test.nguyenminhthe.com
Restore from file:    gdrive-user:n8n-backups/n8n_backup_1.107.2_2025-08-16_09-01-00.tar.gz
Local archive used:   /home/n8n/backups/n8n_backup_1.106.3_2025-08-16_15-55-00.tar.gz
N8N Version:          1.105.3
N8N Directory:        /home/n8n/
Log File:             /root/n8n-main/logs/restore_n8n_2025-08-13_16-39-54.log
Timestamp:            2025-08-13_16-39-54
Volumes Restored:     n8n-data, postgres-data, letsencrypt
PostgreSQL:           Restored from SQL dump
═════════════════════════════════════════════════════════════
```
---

## Scheduling (automatic daily backups)

Here are two easy ways to run your backup every day automatically.

1. Use cron (example: **2:00 AM** daily):

- Create a tiny wrapper script so cron has everything it needs:

```bash
sudo mkdir -p /root/n8n-main/logs
sudo tee /root/n8n-main/run_backup.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /root/n8n-main
# Gmail for notifications
export SMTP_USER="you@YourDomain.com"
export SMTP_PASS="your_app_password"   # Gmail App Password
# Run backup (uploads to Drive + email on failures)
./n8n_backup_restore.sh -b -e you@YourDomain.com -s gdrive-user --notify-on-success >> /root/n8n-main/logs/cron.log 2>&1
EOF
sudo chmod +x /root/n8n-main/run_backup.sh
```

- Schedule it daily at 02:00 (server’s local time)

Use **cron**
```bash
crontab -e
```

Add:
```cron
0 2 * * * /root/n8n-main/run_backup.sh
```

- Want a weekly forced backup as well? Add this extra line to force on Sundays:

```cron
15 2 * * 0 /root/n8n-main/run_backup.sh
```
---

- Check if the crontab was set up correctly:
```cron
crontab -l
```

2. Use systemd timer (resilient & survives reboots)

- Craete Service unit (/etc/systemd/system/n8n-backup.service)

```bash
sudo tee /etc/systemd/system/n8n-backup.service >/dev/null <<'EOF'
[Unit]
Description=n8n daily backup

[Service]
Type=oneshot
WorkingDirectory=/root/n8n
Environment=SMTP_USER=you@YourDomain.com
Environment=SMTP_PASS=your_app_password
ExecStart=/root/n8n-main/n8n_backup_restore.sh -b -e you@YourDomain.com -s gdrive-user --notify-on-success
StandardOutput=append:/root/n8n-main/logs/systemd-backup.log
StandardError=append:/root/n8n-main/logs/systemd-backup.log
EOF
```
- Create the timer (runs 02:05 daily and catches missed runs after reboot):

```bash
sudo tee /etc/systemd/system/n8n-backup.timer >/dev/null <<'EOF'
[Unit]
Description=Run n8n backup daily

[Timer]
OnCalendar=*-*-* 02:05:00
Persistent=true
Unit=n8n-backup.service

[Install]
WantedBy=timers.target
EOF
```

- Enable & start the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now n8n-backup.timer
systemctl list-timers | grep n8n-backup
```
- Check status & logs

```bash
systemctl list-timers | grep n8n-backup
journalctl -u n8n-backup.service --no-pager -n 200
tail -n 200 /root/n8n/logs/systemd-backup.log
```

**Remote cleanup:** files older than **7 days** are deleted from the target folder:

```bash
rclone delete --min-age 7d gdrive-user:n8n-backups
```

(The script runs automatically after each upload.)

---

## Where to check logs

- **Latest run:** printed on screen and written to `logs/`:
  - Backup: `logs/backup_n8n_<YYYY-MM-DD_HH-MM-SS>.log`
  - Restore: `logs/restore_n8n_<YYYY-MM-DD_HH-MM-SS>.log`
- **Email attachment:** on failures (and on success if `-n`), the log file is attached to the email.

---

## Common examples

- Backup to Drive, email on failures only:

  ```bash
  ./n8n_backup_restore.sh -b -e you@YourDomain.com -s gdrive-user
  ```

- Backup to Drive, **always** email (success or failure):

  ```bash
  ./n8n_backup_restore.sh -b -n -e you@YourDomain.com -s gdrive-user
  ```

- Force a backup even if unchanged:

  ```bash
  ./n8n_backup_restore.sh -b -f
  ```

- Restore from a specific file:

  ```bash
  ./n8n_backup_restore.sh -r backups/n8n_backup_1.105.3_2025-08-10_15-31-58.tar.gz
  ```

- Restore from a Google Drive remote path (via rclone):
  ```bash
  ./n8n_backup_restore.sh -r gdrive-user:n8n-backups/n8n_backup_1.107.2_2025-08-16_09-01-00.tar.gz
  ```
---

## Troubleshooting & FAQs

**Q: “Email didn’t send.”**

- Make sure you exported `SMTP_USER` and `SMTP_PASS` in the same shell/cron line.
- Use a **Gmail App Password** (not your normal password).
- Check `logs/backup_n8n_*.log` for `msmtp` errors.

**Q: “Upload went to the wrong Google Drive folder.”**

- Confirm your `-s` is the remote name (e.g., `gdrive-user`).
- Confirm your `-t` is the folder path you intend (e.g., `n8n-backups`).
- Test with `rclone lsd gdrive-user:` and verify.

**Q: “Backup runs every time, even without changes.”**

- First run always backs up and **bootstraps the snapshot**.
- After a successful backup, the script refreshes the snapshot.
- If you still see “changes,” remember that **Postgres** changes files constantly—this script excludes the most noisy dirs (`pg_wal`, `pg_stat_tmp`, `pg_logical`). If you’ve added custom paths inside the volumes, they may legitimately change.

**Q: “Restore failed / unhealthy containers.”**

- Check `logs/restore_n8n_*.log`.
- Run `docker compose ps` and `docker logs <container>` to see details.
- Ensure your `.env` matches the restored DB name (see the note about `n8ndb`).

**Q: “Email attachment looked weird before.”**

- The script now sends a **proper MIME attachment** for the log file.

**Q: “What gets auto‑deleted?”**

- Local: archives older than **7 days** in `backups/`.
- Remote (Drive): files older than **7 days** in your `-t` folder (via `rclone delete --min-age 7d`).

---

## Safety notes

- The archive includes your **database dump** and ``. Treat backups as **sensitive**.
- Keep enough **disk space**—archives can be large, depending on your volumes.
- Test your **restore** at least once so you know the steps and your `.env` database name aligns with the restore.

---

## Support

If you hit a snag:

- Check the run log in `logs/`
- Open an issue on your repo (if applicable)
- Or email: [**wayne.vandervelde@gmail.com**](mailto\:wayne.vandervelde@gmail.com)

Happy automating!
