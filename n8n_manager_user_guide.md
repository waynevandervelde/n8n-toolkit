# n8n Manager — User Guide

**Version:** 1.0.0  
**Author:** TheNguyen  
**Last Updated:** 2025-08-05  

Welcome to the **n8n Manager** script, your one‑stop tool for installing, upgrading, and cleaning up the n8n automation platform using Docker Compose.

---
## Table of Contents

- [Introduction](#introduction)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Install n8n](#install-n8n)
- [Upgrade n8n](#upgrade-n8n)
- [Advanced Options](#advanced-options)
- [Cleanup / Uninstall](#cleanup)
- [Logs and Status](#logs-and-status)
- [Troubleshooting](#troubleshooting)
---

## Introduction

The **n8n Manager** script automates the entire lifecycle of your n8n deployment:

- **Install**: Set up Docker, Docker Compose, SSL certificates, and launch n8n behind Traefik.
- **Upgrade**: Pull the latest n8n image, migrate settings, and restart services.
- **Cleanup**: Remove all containers, volumes, networks, and images to start fresh.

---

## Prerequisites

1. **Linux Server**  
   Ubuntu 20.04+ or Debian with root (or sudo) access.

2. **Domain/Subdomain**  
   e.g. `n8n.example.com`.

3. **DNS A Record**  
   In your DNS provider dashboard:
   - Create an A record for your domain/subdomain
   - Point it at your server’s **public IP**
   - Wait a few minutes for DNS changes to propagate

4. **Open Ports**  
   Ensure ports **80** (HTTP) and **443** (HTTPS) are open in your cloud firewall or server firewall.

5. **Email Address**  
   A valid email (e.g. `you@company.com`) for SSL certificate registration.

---

## Getting Started

1. **Download the Script**  
   ```bash
   apt install unzip
   curl -L -o n8n.zip https://github.com/thenguyenvn90/n8n/archive/refs/heads/main.zip && unzip n8n.zip && cd n8n-main && chmod +x *.sh
   ```
   Note: After unzipping, GitHub appends "-main" to the folder name n8n. In this case, it’s n8n-main.

2. **Run Help**  
   ```bash
   sudo ./n8n_manager.sh -h
   ```
   CLI quick reference (most‑used flags)../
  ```bash
   Usage: ./n8n_manager.sh [-i DOMAIN] [-u DOMAIN] [-v VERSION] [-m EMAIL] [-f] [-c] [-d TARGET_DIR] [-l LOG_LEVEL] -h
     -i <DOMAIN>         Install n8n stack
     -u <DOMAIN>         Upgrade n8n stack
     -v <VERSION>        Pin n8n version (e.g. 1.106.3). Omit or use 'latest' for the latest stable
     -m <EMAIL>          Provide SSL email non‑interactively (skips prompt)
     -f                  Force redeploy/allow downgrade
     -c                  Cleanup all containers, volumes, and network
     -d <DIR>            Install directory (default: current)
     -l <LEVEL>          Log level: DEBUG|INFO|WARN|ERROR
     -h                  Help
   ```
---

## Install n8n

1. Command to install n8n

Interactive email prompt:
```bash
sudo ./n8n_manager.sh -i n8n.YourDomain.com (install the latest n8n version)
or
sudo ./n8n_manager.sh -i n8n.YourDomain.com -v  1.105.3 (install the version 1.105.3)
```

When prompted, enter your email (used for SSL).
```
root@ubuntu-s-1vcpu-1gb-01:~/n8n-main# ./n8n_manager.sh -i n8n.YourDomain.com
[INFO] Working on directory: /root/n8n-main
[INFO] Logging to /root/n8n-main/logs/n8n_manager.log
[INFO] Starting N8N installation for domain: n8n.YourDomain.com
Enter your email address (used for SSL cert): you@YourDomain.com
```

Or provide your SSL email inline (no prompt)

```bash
sudo ./n8n_manager.sh -i n8n.YourDomain.com -m you@YourDomain.com
```
2. Installation Flow

The script will:
   1. **Enter your email** for SSL notifications (if the argument -m was not specified)
   2. **Verify DNS**: script confirms your domain points at this server.
   3. **Copy and configure** `docker-compose.yml` and `.env` with your domain, email, and password.
   4. **Install Docker & Compose** if missing.
   5. **Create volumes** and start the stack behind Traefik.
   6. **Wait for health checks** to pass.

At the end, you’ll see a summary with your URL, version, and log file path.
```
─────────────────────────────────────────────────────────
N8N has been successfully installed!
Domain:             https://n8n.YourDomain.com
Installed Version:  1.105.3
Install Timestamp:  2025-08-13 10:42:14
Installed By:       root
Target Directory:   /root/n8n-main
SSL Email:          you@YourDomain.com
Execution log:      /root/n8n-main/logs/n8n_manager.log
─────────────────────────────────────────────────────────
```
---

## Upgrade n8n

**Upgrade to the latest stable version:**

```bash
sudo ./n8n_manager.sh -u n8n.YourDomain.com
```

**Upgrade to a specific greater version:**

```bash
sudo ./n8n_manager.sh -u n8n.YourDomain.com -v 1.106.3
```

**Upgrade to a specific lower version:** (requires `-f` to proceed)

```bash
sudo ./n8n_manager.sh -u n8n.YourDomain.com -v 1.105.3 -f
```

- On success, you’ll see:
```
─────────────────────────────────────────────────────────
N8N has been successfully upgraded!
Domain:             https://n8n.YourDomain.com
Installed Version:  1.106.3
Install Timestamp:  2025-08-13 10:42:14
Installed By:       root
Target Directory:   /root/n8n-main
SSL Email:          you@YourDomain.com
Execution log:      /root/n8n-main/logs/n8n_manager.log
─────────────────────────────────────────────────────────
```

**Notes:**
- If you **omit `-v`** (or pass `latest`), the script resolves the latest stable tag and updates `.env` to that version.
- If you **pass `-v <version>`**, the script validates the tag, pins it in `.env`, and deploys that exact version.
- A later `-u` **without `-v`** will switch you back to the latest stable.

---

## Advanced Options

- **Target Directory**: By default, uses the current folder. To change:
  ```bash
  mkdir -p /home/n8n
  sudo ./n8n_manager.sh -i n8n.YourDomain.com -d /home/n8n
  ```
- **Log Level** (DEBUG, INFO, WARN, ERROR):
  ```bash
  sudo ./n8n_manager.sh -i n8n.YourDomain.com -l DEBUG
  ```
All logs are written to `/home/n8n/logs/n8n_manager.log`.

---

## Cleanup

If you need to completely remove n8n and start over:

```bash
sudo ./n8n_manager.sh -c
```

> ⚠️ This stops all containers, prunes images, and deletes volumes & networks. Use only if you want a full reset.

---

## Logs and Status

- **Main log file:** `/root/n8n-main/logs/n8n_manager.log`  
- **Check container health:**
  ```bash
  docker compose -f /root/n8n-main/docker-compose.yml ps
  ```
- **Browse UI:** Visit `https://n8n.YourDomain.com` in your web browser.

---

## Troubleshooting

1. **View recent logs:**
   ```bash
   tail -n 50 logs/n8n_manager.log
   ```
2. **Verify DNS:**
   ```bash
   dig +short n8n.YourDomain.com
   ```
3. **Check firewall:**
   ```bash
   sudo ufw status
   ```

Thank you for using **n8n Manager**! If you encounter any issues, please open an issue on the GitHub repo or email [thenguyen.ai.automation@gmail.com](mailto\:thenguyen.ai.automation@gmail.com). 🎉
