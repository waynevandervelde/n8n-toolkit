# Rclone Google Drive Setup Guide (Non-Tech User)

This guide walks you through configuring Rclone on an Ubuntu VPS to upload files *only* into your `n8n-backups` folder in Google Drive—without ever needing a GUI on the server.

---

## 1. Obtain Your OAuth Credentials

1. Open your browser and go to the Google Cloud Console Credentials page:
   ```text
   https://console.cloud.google.com/apis/credentials
   ```
2. Sign in with **your personal** Google account (the one you’ll back up into).
3. In the left menu, click **APIs & Services → Credentials**.
4. Click **+ CREATE CREDENTIALS → OAuth client ID**.
5. Choose **Desktop app** as the application type.
6. Name it `rclone-personal` (or any name you like), then click **Create**.
7. Copy the displayed **Client ID** and **Client Secret** into a text file on your PC.

---

## 2. Add Yourself as a Test User

1. In the left menu of the Cloud Console, click **OAuth consent screen**.
2. Under **Test users**, click **Add users**.
3. Enter your personal Gmail address and click **Save**.

> This step allows you alone to grant access to your "unverified" app.

---

## 3. Perform the Headless OAuth Dance

### A) On Your Windows PC

1. Open **PowerShell** (Win+R → `powershell` → Enter).
2. Run:
   ```powershell
   ssh -N -L 53682:127.0.0.1:53682 root@YOUR_VPS_IP
   ```
   - Replace `YOUR_VPS_IP` with your server’s IP address.
   - Leave this window open the entire time—it forwards port 53682 from the VPS.

### B) On the VPS (New SSH Session)

1. Install Rclone if needed:
   ```bash
   curl https://rclone.org/install.sh | sudo bash
   ```
2. Run the authorize command, pasting your Client ID & Secret:
   ```bash
   rclone authorize "drive"      --client-id YOUR_CLIENT_ID      --client-secret YOUR_CLIENT_SECRET
   ```
3. You’ll see a message:
   ```text
   NOTICE: Failed to open browser.
   Please visit: http://127.0.0.1:53682/auth?state=...
   ```
4. **Copy** that entire URL.

### C) On Your Windows Browser

1. Paste the URL into your browser’s address bar.
2. Sign in, click **Allow** to grant access.
3. The VPS shell will immediately print a single JSON object, for example:
   ```json
   {"access_token":"ya29...","refresh_token":"1//0g...","expiry":"2025-..."}
   ```
4. **Select and copy** that entire `{...}` block.

---

## 4. Create the Rclone Config Manually on the VPS

1. On the VPS, run:
   ```bash
   mkdir -p ~/.config/rclone
   nano ~/.config/rclone/rclone.conf
   ```
2. In the editor, paste exactly:
   ```ini
   [gdrive-user]
   type = drive
   client_id = YOUR_CLIENT_ID
   client_secret = YOUR_CLIENT_SECRET
   scope = drive.file
   root_folder_id = YOUR_FOLDER_ID
   token = PASTED_JSON_BLOCK
   ```
   - **YOUR_FOLDER_ID**: Open your `n8n-backups` folder in Drive and copy the ID after `/folders/` in the URL.
   - **PASTED_JSON_BLOCK**: The JSON object from step 3C, pasted inline (no line breaks).
3. Save and exit:
   - In `nano`, press **Ctrl+O**, Enter, then **Ctrl+X**.

---

## 5. Verify the Setup

### A) List the Folder Contents
```bash
rclone ls gdrive-user:
```
- Should show existing files or nothing (no errors).

### B) Create a Local Test File
```bash
echo "hello from rclone $(date)" > ~/rclone-test.txt
```

### C) Upload the Test File
```bash
rclone copy ~/rclone-test.txt gdrive-user:test.txt
```

### D) Confirm the Upload
```bash
rclone ls gdrive-user:
# You should see a line like:
#   29 test.txt
```

---

## 6. Automate It!

Now that `gdrive-user:` is bound **only** to your `n8n-backups` folder and uses `drive.file` scope, you can safely automate:

```cron
0 2 * * * /usr/bin/rclone copy /path/to/local/dir gdrive-user: --log-file=/var/log/rclone-backup.log
```

This runs every day at 2 AM with zero further clicks.

---

*Enjoy reliable, unattended backups to your Google Drive!*
