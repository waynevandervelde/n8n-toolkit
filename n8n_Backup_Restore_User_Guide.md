# n8n Backup & Restore – User Guide (Non‑Technical)

Simple, reliable backups and restores for an **n8n (Docker)** stack—with optional Google Drive uploads and email notifications.

**Script:** `n8n_backup_restore.sh`\
**Version:** 1.0.0 \
**Last Updated:** 2025-08-10 \
**Author:** TheNguyen · [thenguyen.ai.automation@gmail.com](mailto\:thenguyen.ai.automation@gmail.com)

---

## What this script does

- Backs up Docker **volumes**: `n8n-data`, `postgres-data`, `letsencrypt`
- Creates a **PostgreSQL dump** (from the `postgres` container, DB `n8n`)
- Saves copies of your `` and ``
- **Skips** backup automatically if nothing changed (unless you force it)
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

Install the tools the script needs (Ubuntu/Debian):

```bash
sudo apt-get update
sudo apt-get install -y docker.io rsync tar msmtp-mta rclone \
  dnsutils curl openssl
```

> `getopt` (from util‑linux) is usually already present on Ubuntu.\
> Docker must be running, and your n8n stack should be up via `docker compose`.

---

## Email notifications (optional but recommended)

The script uses **Gmail via msmtp**. Set two environment variables before running:

```bash
export SMTP_USER="youraddress@gmail.com"
export SMTP_PASS="your_app_password"   # Use a Gmail App Password (see below)
```

- **Gmail App Password:**\
  In your Google Account → Security → 2‑Step Verification → **App passwords** → create one (choose “Mail”, device “Other”).\
  Paste that 16‑char password into `SMTP_PASS`.

- Where do emails go? Pass a recipient with `-e you@example.com`.

---

## Google Drive uploads (optional)

1. Configure `rclone` once:

```bash
rclone config      # create a remote, e.g. name it: gdrive-user
```

During `rclone config`, pick **Google Drive**, authorize, and finish.

2. Choose your target folder name in Drive (e.g. `n8n-backups`).\
   The script will upload into that folder under the remote you select.

You’ll pass these when running:

- `-s gdrive-user` (remote name)
- `-t n8n-backups` (folder path within that remote)

> Tip: Verify the path with `rclone lsd gdrive-user:` and `rclone ls gdrive-user:n8n-backups`.

---

## Quick start (most common)

### 1) Normal backup (skip if nothing changed)

```bash
cd /your/project
export SMTP_USER="you@gmail.com"
export SMTP_PASS="app_password"
./n8n_backup_restore.sh -b -e you@gmail.com -s gdrive-user -t n8n-backups
```

### 2) Force a backup (even with no changes)

```bash
./n8n_backup_restore.sh -b -f -e you@gmail.com -s gdrive-user -t n8n-backups
```

### 3) Restore from a backup file

```bash
# Replace the path with your actual file name in /your/project/backups
./n8n_backup_restore.sh -r backups/n8n_backup_1.105.3_2025-08-10_15-31-58.tar.gz
```

---

## Command options (cheat‑sheet)

| Option       | Long form                | Meaning                                                |
| ------------ | ------------------------ | ------------------------------------------------------ |
| `-b`         | `--backup`               | Run a backup (only if changes detected).               |
| `-f`         | `--force`                | Force the backup (ignore change detection).            |
| `-r <FILE>`  | `--restore <FILE>`       | Restore from a backup archive (`.tar.gz`).             |
| `-d <DIR>`   | `--dir <DIR>`            | Base directory of your n8n project (default: current). |
| `-l <LEVEL>` | `--log-level <LEVEL>`    | `DEBUG`, `INFO` (default), `WARN`, `ERROR`.            |
| `-e <EMAIL>` | `--email <EMAIL>`        | Email recipient for notifications.                     |
| `-s <NAME>`  | `--remote-name <NAME>`   | `rclone` remote (e.g., `gdrive-user`).                 |
| `-t <PATH>`  | `--remote-target <PATH>` | Destination path on the remote (e.g., `n8n-backups`).  |
| `-n`         | `--notify-on-success`    | Also email on success (not just on failures).          |
| `-h`         | `--help`                 | Show help.                                             |

**Environment vars used:** `SMTP_USER`, `SMTP_PASS` (for Gmail auth).

---

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

---

## Restore (step by step)

**Warning:** Restore will **stop containers** and **replace volumes** with data from the archive.

1. Make sure you’re in the same project directory that holds your `.env` and `docker-compose.yml`.
2. Run:

```bash
./n8n_backup_restore.sh -r backups/your_backup_file.tar.gz
```

What it does:

- Stops current stack (`docker compose down --volumes --remove-orphans`)
- Removes volumes `n8n-data`, `postgres-data`, `letsencrypt`
- Restores volume archives and the saved `.env` / `docker-compose.yml` (if present)
- Brings the stack back up
- If it finds a SQL dump file, it:
  - Drops and recreates the `` database, and restores into it

> ⚠️ Make sure your `.env` database name matches the one you restore into.\
> This script restores the dump into ``. If your app uses `DB_POSTGRESDB=n8n`, either update `.env` to `n8ndb` or adjust the script/restore step accordingly.

---

## Scheduling (automatic daily backups)

Use cron (example: **2:00 AM** daily):

```bash
crontab -e
```

Add a line (adjust paths/emails/remotes):

```cron
0 2 * * * cd /your/project && \
SMTP_USER="you@gmail.com" SMTP_PASS="app_pass" \
./n8n_backup_restore.sh -b -e you@gmail.com -s gdrive-user -t n8n-backups >> logs/cron.log 2>&1
```

---

## Google Drive path tips

- Use `-t n8n-backups` to upload into a folder named `` at the root of your Drive remote.
- If you want a **subfolder**, use a path like `-t projects/n8n-backups`.
- Verify the folder exists with:
  ```bash
  rclone lsd gdrive-user:
  rclone lsd gdrive-user:projects
  ```
- The script **does not** create nested duplicate folders when you pass a simple leaf name (e.g. `n8n-backups`). If you previously saw `n8n-backups/n8n-backups`, double‑check your `-t` value.

**Remote cleanup:** files older than **7 days** are deleted from the target folder:

```bash
rclone delete --min-age 7d gdrive-user:n8n-backups
```

(The script runs that automatically after each upload.)

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
  ./n8n_backup_restore.sh -b -e you@gmail.com -s gdrive-user -t n8n-backups
  ```

- Backup to Drive, **always** email (success or failure):

  ```bash
  ./n8n_backup_restore.sh -b -n -e you@gmail.com -s gdrive-user -t n8n-backups
  ```

- Force a backup even if unchanged:

  ```bash
  ./n8n_backup_restore.sh -b -f
  ```

- Restore from a specific file:

  ```bash
  ./n8n_backup_restore.sh -r backups/n8n_backup_1.105.3_2025-08-10_15-31-58.tar.gz
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
- Test your **restore** at least once so you know the steps and your `.env` database name align with the restore.

---

## Support

If you hit a snag:

- Check the run log in `logs/`
- Open an issue on your repo (if applicable)
- Or email: [**thenguyen.ai.automation@gmail.com**](mailto\:thenguyen.ai.automation@gmail.com)

Happy automating!

