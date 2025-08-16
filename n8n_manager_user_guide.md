# n8n Manager — User Guide

| **Version** | 1.1.0 |
|-------------|-------|
| **Author**  | TheNguyen |
| **Last Updated** | 2025-08-16 |


Welcome to the **n8n Manager** script, your one‑stop tool for installing, upgrading, and cleaning up the n8n automation platform using Docker Compose.

---
## Table of Contents

- [Introduction](#introduction)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Install n8n](#install-n8n)
- [Upgrade n8n](#upgrade-n8n)
- [Cleanup](#cleanup)
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

6. **System Resources**
   - Minimum: 1 CPU, 2 GB RAM (with swap enabled)
   - Recommended: 2 CPU, 4 GB RAM

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
   CLI quick reference (most‑used flags)
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
        Target install directory (default: $PWD)

  -l, --log-level <LEVEL>
        Set log level: DEBUG, INFO (default), WARN, ERROR

  -h, --help
        Show script usage

Examples:
  ./n8n_manager.sh -a
      # List available versions

  ./n8n_manager.sh -i n8n.YourDomain.com -m you@YourDomain.com -d /home/n8n
      # Install the latest n8n version

  ./n8n_manager.sh -i n8n.YourDomain.com -m you@YourDomain.com -v 1.105.3 -d /home/n8n
      # Install a specific n8n version

  ./n8n_manager.sh -u n8n.YourDomain.com -d /home/n8n
      # Upgrade to the latest n8n version

  ./n8n_manager.sh -u n8n.YourDomain.com -f -v 1.107.2 -d /home/n8n
      # Upgrade to a specific n8n version

  ./n8n_manager.sh -c
      # Cleanup everything
   ```
---

## Install n8n


1. **List all available n8n version**
```bash
sudo ./n8n_manager.sh -a
```
Example log:
```bash
Top 5 latest stable n8n versions (no running version detected):
1.106.2
1.106.3
1.107.0
1.107.1
1.107.2
```

2. **Command to install n8n**

Interactive email prompt:
```bash
# Install the latest n8n version
sudo ./n8n_manager.sh -i n8n.YourDomain.com -m you@YourDomain.com -d /home/n8n

# Install a specific n8n version
sudo ./n8n_manager.sh -i n8n.YourDomain.com -m you@YourDomain.com -v 1.105.3 -d /home/n8n
```

> ⚠️ Make sure your DNS is already propagated before running the installation. Otherwise, SSL will fail.

2. **Installation Flow**

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
Target Directory:   /home/n8n
SSL Email:          you@YourDomain.com
Execution log:      /home/n8n/logs/n8n_manager.log
─────────────────────────────────────────────────────────
```
---

## Upgrade n8n

**Upgrade to the latest stable version:**

```bash
sudo ./n8n_manager.sh -u n8n.YourDomain.com -d /home/n8n
```

**Upgrade to a specific greater version:**

```bash
sudo ./n8n_manager.sh -u n8n.YourDomain.com -v 1.106.3 -d /home/n8n
```

**Upgrade to a specific lower version:** (requires `-f` to proceed)

```bash
sudo ./n8n_manager.sh -u n8n.YourDomain.com -v 1.105.3 -f -d /home/n8n
```

- On success, you’ll see:
```
─────────────────────────────────────────────────────────
N8N has been successfully upgraded!
Domain:             https://n8n.YourDomain.com
Installed Version:  1.106.3
Install Timestamp:  2025-08-13 10:42:14
Installed By:       root
Target Directory:   /home/n8n
SSL Email:          you@YourDomain.com
Execution log:      /home/n8n/logs/n8n_manager.log
─────────────────────────────────────────────────────────
```

**Notes:**
- If you **omit `-v`** (or pass `latest`), the script resolves the latest stable tag and updates `.env` to that version.
- If you **pass `-v <version>`**, the script validates the tag, pins it in `.env`, and deploys that exact version.
- A later `-u` **without `-v`** will switch you back to the latest stable.

---

## Cleanup

If you need to completely remove n8n and start over:

```bash
sudo ./n8n_manager.sh -c -d /home/n8n
```

> ⚠️ This stops all containers, prunes images, and deletes volumes & networks. Use only if you want a full reset.

---

## Logs and Status

- **Main log file:** `/home/n8n/logs/n8n_manager.log`  
- **Check container health:**
  ```bash
  docker compose -f /home/n8n/docker-compose.yml ps
  ```
- **Browse UI:** Visit `https://n8n.YourDomain.com` in your web browser.

---

## Troubleshooting

1. **View the installation logs:**
   ```bash
   cat /home/n8n/logs/n8n_manager.log
   ```
2. **Verify DNS:**
   ```bash
   dig +short n8n.YourDomain.com
   ```
2. **Check the container logs:**
   ```bash
   docker logs -f traefik
   docker logs -f n8n
   ```

Thank you for using **n8n Manager**! If you encounter any issues, please open an issue on the GitHub repo or email [thenguyen.ai.automation@gmail.com](mailto\:thenguyen.ai.automation@gmail.com). 🎉
