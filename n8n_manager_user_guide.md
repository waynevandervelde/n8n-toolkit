# n8n Manager — User Guide

**Version:** 1.0.0  
**Author:** TheNguyen  
**Last Updated:** 2025-08-05  

This guide walks non-technical users through installing, upgrading, and cleaning up the n8n automation platform using the `n8n_manager.sh` script.

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
   curl -LO https://github.com/thenguyenvn90/n8n/n8n_manager.sh && chmod +x n8n_manager.sh
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

> ⚠️ This deletes **all** user data volumes. Use only if you want a full reset.

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

- **Custom install directory:**
  ```bash
  sudo ./n8n_manager.sh -i n8n.example.com -d /opt/n8n
  ```
- **Verbose (DEBUG) output:**
  ```bash
  sudo ./n8n_manager.sh -i n8n.example.com -l DEBUG
  ```

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

Happy automating with n8n! 🎉
