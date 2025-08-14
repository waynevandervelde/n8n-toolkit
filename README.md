Self-Hosted n8n Orchestration &amp; Automation Toolkit
# n8n Stack — Installer, Manager, and Backup/Restore

> Turn-key scripts to **install, upgrade, and manage** an n8n stack (Docker Compose), plus a **reliable backup/restore** tool with optional Google Drive sync and email notifications.

**Author:** TheNguyen · thenguyen.ai.automation@gmail.com  
**Version:** 1.0.0 (manager) · 1.2.0 (backup/restore)  
**OS:** Ubuntu/Debian (root or sudo)

---

## Table of Contents

- [Overview](#overview)
- [Repository Layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Install n8n (Manager Script)](#install-n8n-manager-script)
- [Upgrade / Pin a Version](#upgrade--pin-a-version)
- [Cleanup / Uninstall](#cleanup--uninstall)
- [Backups](#backups)
- [Restore](#restore)
- [Scheduling Daily Backups](#scheduling-daily-backups)
- [Email and Google Drive Setup](#email-and-google-drive-setup)
- [Troubleshooting](#troubleshooting)
- [Security Notes](#security-notes)
- [Support](#support)

---

## Overview

This repo contains two production-ready bash scripts:

1. **`n8n_manager.sh`** — installs, upgrades, and manages an n8n stack using Docker Compose.
   - Validates your **domain DNS** points to the server
   - Installs **Docker Engine** & **Docker Compose v2** (if needed)
   - Creates persistent volumes: `n8n-data`, `postgres-data`, `letsencrypt`
   - Runs health checks and validates HTTPS/SSL
   - Supports **version pinning** (`-v`) and **non-interactive SSL email** (`-m`)
   - Force redeploy / allow downgrade with `-f`
   - Full cleanup mode

2. **`n8n_backup_restore.sh`** — safely backs up & restores your stack.
   - Archives **volumes** and **Postgres dump**
   - Saves `.env` & `docker-compose.yml`
   - **Change detection** (skips redundant backups unless `--force`)
   - **30‑day rolling summary** (`backups/backup_summary.md`)
   - Optional **Google Drive upload** via `rclone`
   - Optional **email notifications** via Gmail/`msmtp` (attaches logs on failure)

---

## Repository Layout

```
.
├── n8n_manager.sh             # Installer / upgrader / cleanup
├── n8n_backup_restore.sh      # Backup & restore tool
├── docker-compose.yml         # Template Compose file
├── .env                       # Template env file (will be updated by scripts)
├── logs/                      # Created on first run
└── backups/                   # Created by backup script (archives, summary, snapshot/)
```

> Keep `docker-compose.yml` and `.env` in the **same folder** where you run the scripts.

---

## Prerequisites

- **Domain / subdomain** (e.g. `n8n.example.com`) pointing to **this server’s public IP**
- **Ports 80 & 443 open** on your firewall/cloud provider
- Ubuntu/Debian server (root or sudo)
- Internet access (to pull Docker images and packages)

> The manager script installs required packages automatically (Docker, Compose, jq, etc.).

---

## Quick Start

Clone and make scripts executable:

```bash
git clone https://github.com/thenguyenvn90/n8n.git
cd n8n
chmod +x n8n_manager.sh n8n_backup_restore.sh
```

**Install (interactive email prompt):**

```bash
sudo ./n8n_manager.sh -i n8n.example.com
```

**Install (non‑interactive email):**

```bash
sudo ./n8n_manager.sh -i n8n.example.com -m you@example.com
```

After a successful install, visit: `https://n8n.example.com`

---

## Install n8n (Manager Script)

**Basic syntax**
```bash
sudo ./n8n_manager.sh -i <DOMAIN> [-m <SSL_EMAIL>] [-d <DIR>] [-l <LEVEL>]
```

**Examples**
```bash
# Install to current directory, prompt for email
sudo ./n8n_manager.sh -i n8n.example.com

# Install to /opt/n8n and provide email non-interactively
sudo ./n8n_manager.sh -i n8n.example.com -m you@example.com -d /opt/n8n
```

**What it does**
1. Confirms your domain resolves to this server’s public IP.
2. Installs Docker Engine & Compose v2 (if needed).
3. Copies/updates `docker-compose.yml` and `.env`.
4. Injects `DOMAIN`, `SSL_EMAIL`, and a strong password.
5. Resolves an **n8n image tag** (see versioning below) and writes it as `N8N_IMAGE_TAG` in `.env`.
6. Starts the stack and waits for healthy containers and valid TLS.

**Key flags**
- `-i <DOMAIN>` — required for install
- `-m <EMAIL>` — provide SSL email non‑interactively (skips prompt)
- `-d <DIR>` — target install directory (default: current directory)
- `-l <LEVEL>` — log level: `DEBUG`, `INFO` (default), `WARN`, `ERROR`

---

## Upgrade / Pin a Version

**Latest stable (auto‑resolved):**
```bash
sudo ./n8n_manager.sh -u n8n.example.com
```

**Pin to a specific version (e.g. 1.106.3):**
```bash
sudo ./n8n_manager.sh -u n8n.example.com -v 1.106.3
```

**Force redeploy or allow downgrade:**
```bash
sudo ./n8n_manager.sh -u n8n.example.com -v 1.105.3 -f
```

**How version selection works**
- If you **omit `-v`** or pass `-v latest`, the script resolves the latest **stable** n8n tag from Docker Hub and sets `N8N_IMAGE_TAG` in `.env`.
- If you **pass `-v X.Y.Z`**, the script validates that tag and pins it in `.env`.
- A future `-u` **without `-v`** switches back to the latest stable.
- Downgrades require `-f`.

---

## Cleanup / Uninstall

```bash
sudo ./n8n_manager.sh -c
```
Stops/removes containers, prunes images, and deletes the `n8n-data`, `postgres-data`, and `letsencrypt` volumes and the `n8n_network` (if present). You’ll be prompted for confirmation.

---

## Backups

**Normal backup (skips if no changes):**
```bash
./n8n_backup_restore.sh -b -e you@gmail.com -s gdrive-user -t n8n-backups
```

**Force backup:**
```bash
./n8n_backup_restore.sh -b -f -e you@gmail.com -s gdrive-user -t n8n-backups
```

**What’s backed up**
- Volumes: `n8n-data`, `postgres-data`, `letsencrypt`
- Postgres dump from the `postgres` container (DB `n8n`)
- `.env` and `docker-compose.yml` copies
- A rolling `backups/backup_summary.md` (30 days)

**Outputs**
- Archive: `backups/n8n_backup_<N8N_VERSION>_<YYYY-MM-DD_HH-MM-SS>.tar.gz`
- Log: `logs/backup_n8n_<timestamp>.log`

**Change detection**
The script compares live data to a `backups/snapshot/` mirror and **skips** creating a new archive if nothing changed (unless `-f`).

---

## Restore

> ⚠️ Restore **stops the stack and replaces volumes** with the archive contents.

```bash
./n8n_backup_restore.sh -r backups/n8n_backup_1.106.3_2025-08-10_15-31-58.tar.gz
```

What it does:
- `docker compose down --volumes --remove-orphans`
- Removes `n8n-data`, `postgres-data`, `letsencrypt`
- Restores volumes + `.env` / `docker-compose.yml` (if present)
- Brings the stack up
- If a SQL dump is included, it drops & recreates the **`n8ndb`** database and restores into it

> Ensure your `.env` DB name aligns with the restored DB (script restores to `n8ndb`).

---

## Scheduling Daily Backups

Use **cron** (example: run at 2:00 AM daily):

```bash
crontab -e
```

Add:
```cron
0 2 * * * cd /path/to/n8n && \
SMTP_USER="you@gmail.com" SMTP_PASS="app_password" \
./n8n_backup_restore.sh -b -e you@gmail.com -s gdrive-user -t n8n-backups >> logs/cron.log 2>&1
```

---

## Email and Google Drive Setup

### Email via Gmail (`msmtp`)
Export once per session (or inline in cron):
```bash
export SMTP_USER="youraddress@gmail.com"
export SMTP_PASS="your_gmail_app_password"
```
- Use a **Gmail App Password** (Google Account → Security → App passwords).

Add `-e you@example.com` to receive notifications. On failures, the log file is attached.

### Google Drive via `rclone`
1. Run `rclone config` and create a remote (e.g., `gdrive-user`).
2. Use `-s gdrive-user` (remote) and `-t n8n-backups` (folder path).  
   Test with `rclone lsd gdrive-user:`.

Old remote files older than **7 days** are pruned automatically.

---

## Troubleshooting

- **“Not: command not found” when running a script**  
  You likely downloaded a web page instead of the raw script. Ensure you cloned the repo or fetched the **raw** file.

- **DNS check fails**  
  `dig +short n8n.example.com` must show your server’s public IP (`curl -s https://api.ipify.org`). Update your DNS A record if needed.

- **Port 80/443 already in use**  
  Stop other web servers (Apache/Nginx) or change their ports before install.

- **SSL not issued**  
  Ports 80/443 must be open, domain must resolve correctly, and Traefik must be running.

- **Backups run every time**  
  First run bootstraps the snapshot. Subsequent runs skip if no changes are detected (unless `-f`).

- **Email didn’t send**  
  Use a Gmail **App Password** and ensure `SMTP_USER/SMTP_PASS` are set in the same shell/cron line.

- **Google Drive uploaded to wrong folder**  
  Double‑check `-s` (remote name) and `-t` (remote path). Verify with `rclone lsd`.

---

## Security Notes

- Backup archives include your **database dump** and secrets from `.env`. Treat them as **sensitive**.
- Limit access to the server and protect the `backups/` and `logs/` directories.
- Test **restore** at least once to ensure everything matches your environment.

---

## Support

- Open an issue in the repo, or  
- Email **thenguyen.ai.automation@gmail.com**

Happy automating! 🚀
