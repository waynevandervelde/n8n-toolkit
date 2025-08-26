# Self-Hosted n8n — Install, Upgrade, and Backup/Restore

Automate the **install**, **upgrade**, **backup**, and **restore** of an [n8n](https://n8n.io/) stack running on Docker.  
This repository provides a **production-ready setup** for **self-hosting n8n** with **Docker Compose**, **Traefik** (for HTTPS & reverse proxy), and **PostgreSQL** (for reliable persistence).  
Whether you’re a developer or a non-technical user, this setup makes it simple to run your own secure automation platform.

Refer to my blog post: [https://nextgrowth.ai/self-host-n8n-automation-ubuntu-docker/](https://nextgrowth.ai/self-host-n8n-automation-ubuntu-docker/)

## Table of Contents

- [Highlights](#highlights)  
- [Repository Layout](#repository-layout)  
- [Prerequisites](#prerequisites)  
- [Quick Start](#quick-start)  
  - [Get the Repository](#get-the-repository)  
  - [Install n8n](#install-n8n)  
  - [Backup and restore n8n](#backup-and-restore-n8n)  
- [Support](#support)

---

## Highlights

- **Automated lifecycle** — scripts to install, upgrade, backup, and restore your n8n stack.  
- **Single-mode deployment** — run editor, webhooks, and workflow execution in one simple container.  
- **Secure by default** — HTTPS with Traefik + Let’s Encrypt (auto-renew), strong encryption, and Basic Auth protection.  
- **Reliable data storage** — PostgreSQL database for workflows & credentials, with persistent volumes for durability.  
- **Persistent by design** — database, n8n data, and SSL certificates survive restarts and upgrades.  
- **User-friendly for all** — clear instructions so developers and non-technical users can both succeed.  
- **Stable & monitored** — built-in health checks for all containers.  
- **Production-ready** — secure configs, environment variables, and best practices already applied.  

---

## Repository Layout

```
.
├── n8n_manager.sh                       # Script: Install / Upgrade / Cleanup the stack
├── n8n_backup_restore.sh                # Script: Backup / Restore + Google Drive + Email support
├── docker-compose.yml                   # Main Compose file (defines n8n + Postgres + Traefik stack)
├── .env                                 # Environment configuration (domain, credentials, DB, SSL, etc.)
├── n8n_manager_user_guide.md            # User guide for install, upgrade, cleanup
├── n8n_Backup_Restore_User_Guide.md     # User guide for backup and restore
└── README.md
```

> Key Files
- **`docker-compose.yml`**: Defines the entire stack: n8n, PostgreSQL, Traefik. This is the *engine* of your deployment.  
- **`.env`**: Central configuration file. Here you set your domain, SSL email, database credentials, and more.  
  - **⚠️ N8N_ENCRYPTION_KEY is critical**:  
    - Used to encrypt all saved credentials in n8n.  
    - Must be set during **installation** and kept the same across **upgrades, backups, and restores**.  
    - If you lose or change it, all previously stored credentials become unusable, even if you restore from a backup.  
---

## Prerequisites

- **Domain / subdomain** (e.g. `n8n.example.com`) pointing to **this server’s public IP**  
- **Ports 80 & 443 open** on your firewall/cloud provider  
- **Ubuntu/Debian server** (with root or sudo access)  
- **Internet access** (to pull Docker images and packages)  
- **Recommended server resources**:  
  - Minimum: **1 vCPU, 2 GB RAM, 20 GB disk** (good for testing or light workloads)  
  - Recommended: **2 vCPU, 4 GB RAM, 40+ GB disk** (stable for production use)  
  - Scale up if you expect **many concurrent workflows** or large data processing  

---

## Quick Start

### Get the Repository

You can set up this project in **two different ways**, depending on your experience:

#### Option 1 — For developers (using Git)
If you already have `git` installed and are comfortable with it:

```bash
git clone https://github.com/thenguyenvn90/n8n.git
cd n8n
chmod +x *.sh
```

#### Option 2 — For non-tech users (download as ZIP)
If you don’t use Git, you can just download the code directly:

```bash
# Install unzip if not available
sudo apt install unzip -y

# Download and extract
curl -L -o n8n.zip https://github.com/waynevandervelde/n8n-toolkit/archive/refs/heads/main.zip
unzip n8n.zip
cd n8n-main
# Make scripts executable
chmod +x *.sh
```
Note: After unzipping, GitHub appends -main to the folder name. Instead of n8n/, the folder will be called n8n-main/.

---

### Install n8n

The `n8n_manager.sh` script is the main tool to **install, upgrade, and cleanup** your n8n stack.  
It automates the entire lifecycle of the deployment so you don’t need to remember long Docker commands.

**Basic syntax**
```bash
   Usage: ./n8n_manager.sh [OPTIONS]
   
   Options:
     -a, --available
           List available n8n versions
           * If n8n is running → show all newer versions than current
           * If n8n is not running → show top 5 latest versions
   
     -i, --install <DOMAIN>
           Install n8n stack with specified domain
           Use -v|--version to specify a version
   
     -u, --upgrade <DOMAIN>
           Upgrade n8n stack with specified domain
           Use -f|--force to force upgrade/downgrade
           Use -v|--version to specify a version
   
     -v, --version <N8N_VERSION>
           Install/upgrade with a specific n8n version. If omitted/empty, uses latest-stable
   
     -m, --email <SSL_EMAIL>
           Email address for Let's Encrypt SSL certificate
   
     -c, --cleanup
           Cleanup all containers, volumes, and network
   
     -d, --dir <TARGET_DIR>
           /path/to/n8n: your n8n project directory (default: /home/n8n)
   
     -l, --log-level <LEVEL>
           Set log level: DEBUG, INFO (default), WARN, ERROR
   
     -h, --help
           Show script usage
```

**Key Features**
- **Install** — set up n8n with Docker Compose, Traefik, and PostgreSQL in one command.  
- **Upgrade** — update n8n to the latest (or specific) version while keeping data safe.  
- **Cleanup** — remove unused containers, images, and volumes.  
- **Logs** — view container logs for debugging.  
- **Secure defaults** — auto-configures HTTPS, Basic Auth, and persistence.  

**What it does**
1. Confirms your domain resolves to this server’s public IP.  
2. Installs Docker Engine & Compose v2 (if needed).  
3. Copies/updates `docker-compose.yml` and `.env`.  
4. Injects key variables:  
   - `DOMAIN`  
   - `SSL_EMAIL`  
   - `N8N_ENCRYPTION_KEY` (critical for encrypted credentials)  
   - `N8N_IMAGE_TAG` (version to deploy)  
   - `STRONG_PASSWORD` (used for n8n & PostgreSQL).  
5. Deploys the n8n stack using Docker Compose and sets up SSL certificates.  
6. Runs health checks and validates HTTPS/SSL status.  
7. Supports **force redeploy** or even **downgrade** with the `-f` flag.  
8. Provides **full cleanup mode** to remove all containers, images, and volumes if needed.  

👉 For detailed usage (all flags, examples, and advanced scenarios), see the full guide: [**n8n_manager_user_guide.md**](./n8n_manager_user_guide.md)

---

### Backup and restore n8n

The `n8n_backup_restore.sh` script handles **backups and restores** of your n8n stack, including volumes, database, configs, and optional cloud storage.

**Basic syntax**
```bash
   Usage: ./n8n_backup_restore.sh [OPTIONS]

   Options:
     -b, --backup
           Perform backup
   
     -f, --force
           Force backup even if no changes detected
   
     -r, --restore <FILE>
           Restore from backup file
   
     -d, --dir <DIR>
           /path/to/n8n project directory (default: /home/n8n)
   
     -m, --email <EMAIL>
           Send email alerts to this address
   
     -s, --remote-name <NAME>
           Rclone remote name (e.g. gdrive-user)
   
     -n, --notify-on-success
           Email on successful completion
   
     -l, --log-level <LEVEL>
           Set log level: DEBUG, INFO (default), WARN, ERROR
   
     -h, --help
           Show script usage
```

**Key Features**
- **Checks N8N_ENCRYPTION_KEY** — ensures it is set before any backup (required for credential security).
- **Backs up Docker volumes**: `n8n-data`, `postgres-data`, `letsencrypt`  
- **Creates a PostgreSQL dump** (from the `postgres` container, DB `n8n`)  
- **Copies configs** (`.env`, `docker-compose.yml`) into the backup  
- **Smart change detection** — skips backup if nothing has changed (unless forced with `-f`)  
- **Keeps 30-day rolling summary** in `backups/backup_summary.md`  
- **Optional Google Drive upload** (via `rclone`)  
- **Email alerts** via Gmail SMTP (`msmtp`) with log file attached (on failure, or optionally on success)
- **Restore** from a backup archive stored **locally** or from **Google Drive** (via rclone).  

👉 For detailed usage (all flags, examples, and advanced scenarios), see the full guide: [`n8n_Backup_Restore_User_Guide.md`](./n8n_Backup_Restore_User_Guide.md)

---

## Support

- Open an issue in the repo, or  
- Email **wayne.vandervelde@gmail.com**

Happy automating!
