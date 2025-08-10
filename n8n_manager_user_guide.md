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
   curl -L -o n8n_manager.sh https://raw.githubusercontent.com/thenguyenvn90/n8n/main/n8n_manager.sh && chmod +x n8n_manager.sh
   ```

2. **Run Help**  
   ```bash
   sudo ./n8n_manager.sh -h
   ```
   You should see usage instructions.

---

## 🔧 Install n8n

```bash
sudo ./n8n_manager.sh -i n8n.example.com
```

1. When prompted, enter your email (used for SSL).  
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
   Domain:             https://n8n.example.com
   Installed Version:  1.105.3
   Execution log:      /path/to/logs/n8n_manager.log
   ─────────────────────────────────────────────────────────
   ```

---

## 🔄 Upgrade n8n

Pull and deploy the latest n8n release:

```bash
sudo ./n8n_manager.sh -u n8n.example.com
```

- If already up-to-date, the script reports it.  
- To force an upgrade even if on the latest version, add `-f`:

  ```bash
  sudo ./n8n_manager.sh -u -f n8n.example.com
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

- **Main log file:** `logs/n8n_manager.log`  
- **Check container health:**
  ```bash
  docker compose -f /path/to/docker-compose.yml ps
  ```
- **Browse UI:** Visit `https://n8n.example.com` in your web browser.

---

## ⚙️ Advanced Options

- **Target Directory**: By default uses current folder. To change:
  ```bash
  sudo ./n8n_manager.sh -i n8n.example.com -d /opt/n8n
  ```
- **Log Level** (DEBUG, INFO, WARN, ERROR):
  ```bash
  sudo ./n8n_manager.sh -i n8n.example.com -l DEBUG
  ```
All logs write to `TARGET_DIR/logs/n8n_manager.log`.

---

## 🤝 Support & Troubleshooting

1. **View recent logs:**
   ```bash
   tail -n 50 logs/n8n_manager.log
   ```
2. **Verify DNS:**
   ```bash
   dig +short n8n.example.com
   ```
3. **Check firewall:**
   ```bash
   sudo ufw status
   ```

Thank you for using **n8n Manager**! If you encounter any issues, please open an issue on the GitHub repo or email [thenguyen.ai.automation@gmail.com](mailto\:thenguyen.ai.automation@gmail.com). 🎉
