# n8n Manager — User Guide

**Version:** 1.0.0  
**Author:** TheNguyen  
**Last Updated:** 2025-08-05  

Welcome to the **n8n Manager** script, your one‑stop tool for installing, upgrading, and cleaning up the n8n automation platform using Docker Compose. This guide is written for non‑technical users and walks you through all the steps and common scenarios.

---

## 📖 Introduction

The **n8n Manager** script automates the entire lifecycle of your n8n deployment:

- **Install**: Set up Docker, Docker Compose, SSL certificates, and launch n8n behind Traefik.
- **Upgrade**: Pull the latest n8n image, migrate settings, and restart services.
- **Cleanup**: Remove all containers, volumes, networks, and images to start fresh.

---

## 📋 Prerequisites

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

## 🚀 Getting Started

1. **Download the Script**  
   ```bash
   apt install unzip
   curl -L -o n8n.zip https://github.com/thenguyenvn90/n8n/archive/refs/heads/main.zip && unzip n8n.zip && cd n8n-main && chmod +x *.sh
   ```
   Note: After unzipping, GitHub appends -main to the folder name n8n; So in this case it’s n8n-main.

2. **Run Help**  
   ```bash
   sudo ./n8n_manager.sh -h
   ```
   You should see usage instructions../
   ```
   root@ubuntu-s-1vcpu-1gb-01://n8n-main# ./n8n_manager.sh -h
   Usage: ./n8n_manager.sh [-i DOMAIN] [-u DOMAIN] [-f] [-c] [-d TARGET_DIR] [-l LOG_LEVEL] -h
     ./n8n_manager.sh -i <DOMAIN>         Install n8n stack
     ./n8n_manager.sh -u <DOMAIN> [-f]    Upgrade n8n stack (optionally force) to the latest version
     ./n8n_manager.sh -c                  Cleanup all containers, volumes, and network
     ./n8n_manager.sh -d <TARGET_DIR>     Target install directory (default: /root/n8n-main)
     ./n8n_manager.sh -l                  Set log level: DEBUG, INFO (default), WARN, ERROR
     ./n8n_manager.sh -h                  Show script usage
   ```
---

## 🔧 Install n8n

```bash
sudo ./n8n_manager.sh -i n8n.YourDomain.com
```

1. When prompted, enter your email (used for SSL).
```
   root@ubuntu-s-1vcpu-1gb-01:~/n8n-main# ./n8n_manager.sh -i n8n.YourDomain.com
   [INFO] Working on directory: /root/n8n-main
   [INFO] Logging to /root/n8n-main/logs/n8n_manager.log
   [INFO] Starting N8N installation for domain: n8n.YourDomain.com
   Enter your email address (used for SSL cert): yourValidEmail@gmail.com
```
2. The script will:
   - Verify your DNS record
   - Install Docker & Docker Compose if needed
   - Create required Docker volumes
   - Generate a strong password and update `.env`
   - Start the n8n Docker stack

3. On success, you’ll see:
   ```
   ─────────────────────────────────────────────────────────
   N8N has been successfully installed!
   Domain:             https://n8n.YourDomain.com
   Installed Version:  1.105.3
   Install Timestamp:  2025-08-13 10:42:14
   Installed By:       root
   Target Directory:   /root/n8n-main
   SSL Email:          yourValidEmail@gmail.com
   Execution log:      /root/n8n-main/logs/n8n_manager.log
   ─────────────────────────────────────────────────────────
   ```

---

## 🔄 Upgrade n8n

Pull and deploy the latest n8n release:

```bash
sudo ./n8n_manager.sh -u n8n.YourDomain.com
```

- If already up-to-date, the script reports it.
  ```
   root@ubuntu-s-1vcpu-1gb-sgp1-01:/root/n8n-main# ./n8n_manager.sh -u n8n-test.YourDomain.com
   [INFO] Working on directory: /root/n8n-main
   [INFO] Logging to /root/n8n-main/logs/n8n_manager.log
   [INFO] Checking current and latest n8n versions...
   [INFO] Current version: 1.106.3
   [INFO] Latest version:  1.106.3
   [INFO] You are already running the latest version (1.106.3). Use -f to force upgrade.
  ```
- To force an upgrade even if on the latest version, add `-f`:

  ```bash
  sudo ./n8n_manager.sh -u -f n8n.YourDomain.com
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
   SSL Email:          yourValidEmail@gmail.com
   Execution log:      /root/n8n-main/logs/n8n_manager.log
   ─────────────────────────────────────────────────────────
  ```
---

## 🧹 Cleanup (Uninstall)

Completely remove n8n containers, volumes, and network:

```bash
sudo ./n8n_manager.sh -c
```

> ⚠️ This stops all containers, prunes images, and deletes volumes & networks. Use only if you want a full reset.

---

## 🗂️ Logs & Status

- **Main log file:** `/root/n8n-main/logs/n8n_manager.log`  
- **Check container health:**
  ```bash
  docker compose -f /root/n8n-main/docker-compose.yml ps
  ```
- **Browse UI:** Visit `https://n8n.YourDomain.com` in your web browser.

---

## ⚙️ Advanced Options

- **Target Directory**: By default uses current folder. To change:
  ```bash
  mkdir -p /home/n8n
  sudo ./n8n_manager.sh -i n8n.YourDomain.com -d /home/n8n
  ```
- **Log Level** (DEBUG, INFO, WARN, ERROR):
  ```bash
  sudo ./n8n_manager.sh -i n8n.YourDomain.com -l DEBUG
  ```
All logs write to `/home/n8n/logs/n8n_manager.log`.

---

## 🤝 Support & Troubleshooting

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
