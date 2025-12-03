# Backblaze Personal + Network Share Backup (via Dokan)

Backup your NAS/network shares with Backblaze Personal using Dokan as a filesystem bridge.

## The Problem

Backblaze Personal doesn't officially support backing up network shares (SMB/NAS). When you try workarounds, you hit **Error 1307 (invalid owner)** because the Backblaze service runs as `SYSTEM`, which can't properly authenticate to SMB shares.

## The Solution

Use **[Dokan](https://github.com/dokan-dev/dokany)** (a Windows filesystem driver) to mount the SMB share as a local drive, and run the Backblaze service under a **local user account** instead of SYSTEM.

### How it works:
1. Dokan's `mirror.exe` presents the SMB share as a local drive (e.g., `X:`)
2. A local user account is created with the necessary permissions
3. The Backblaze service (`bzserv`) runs under this local account
4. Backblaze sees `X:` as a normal local drive and backs it up

## Quick Setup

### Prerequisites
- Windows 10/11
- [Dokan Library 2.x](https://github.com/dokan-dev/dokany/releases) installed
- Backblaze Personal installed
- Admin privileges
- SMB share accessible from this machine

### Automated Setup

1. Download `backblaze-smb-backup-setup.ps1` from this repo
2. Run PowerShell **as Administrator**
3. Execute:

```powershell
powershell -ExecutionPolicy Bypass -File .\backblaze-smb-backup-setup.ps1 -SMBPath "\\YOUR-NAS-IP\sharename" -DriveLetter "X" -Password "YourSecurePassword123!"
```

If your NAS requires authentication, add the NAS credentials:

```powershell
powershell -ExecutionPolicy Bypass -File .\backblaze-smb-backup-setup.ps1 -SMBPath "\\YOUR-NAS-IP\sharename" -DriveLetter "X" -Password "YourSecurePassword123!" -NASUser "nasuser" -NASPassword "naspassword"
```

> **Note:** If you get an execution policy error, use the command above with `-ExecutionPolicy Bypass`, or run `Unblock-File .\backblaze-smb-backup-setup.ps1` first.

The script will:
- Create a local user account (`BackblazeUser`)
- Configure the Backblaze service to run under that account
- Create a scheduled task to auto-mount the drive at startup
- Mount the drive immediately

Then just add the new drive in Backblaze settings!

---

## Manual Setup

If you prefer to do it manually:

### 1. Install Dokan
- Download from: https://github.com/dokan-dev/dokany/releases
- Install **Dokan Library 2.x** (includes `mirror.exe` sample)

### 2. Create a local user account
```powershell
$password = ConvertTo-SecureString "YourPassword123!" -AsPlainText -Force
New-LocalUser -Name "BackblazeUser" -Password $password -PasswordNeverExpires
Add-LocalGroupMember -Group "Administrators" -Member "BackblazeUser"
```

### 3. Configure Backblaze service to run as the new user
```cmd
sc config "bzserv" obj= ".\BackblazeUser" password= "YourPassword123!"
net stop bzserv
net start bzserv
```

### 4. Mount the SMB share with Dokan
```cmd
"C:\Program Files\Dokan\Dokan Library-2.3.1\sample\mirror\mirror.exe" /r \\YOUR-NAS-IP\sharename /l X:
```

### 5. Add drive to Backblaze
- Open Backblaze Settings → Hard Drives
- Check the box for drive `X:`

### 6. Create a scheduled task for persistence
So the mount survives reboots:
- Task: Run `mirror.exe /r \\server\share /l X:` at startup
- Run as: `BackblazeUser`
- Run with highest privileges

---

## Troubleshooting

### Drive doesn't appear after reboot
- Check if the scheduled task ran: `Get-ScheduledTask -TaskName "DokanMirror-X"`
- Manually start: `Start-ScheduledTask -TaskName "DokanMirror-X"`
- Check Event Viewer for Dokan errors

### Backblaze not scanning the drive
- Verify Backblaze service is running as the correct user:
  ```powershell
  Get-WmiObject win32_service | Where-Object {$_.Name -eq 'bzserv'} | Select-Object StartName
  ```
- Restart Backblaze service after mounting the drive

### Error 1307 still occurring
- This means Backblaze is still running as SYSTEM
- Double-check the `sc config` command ran successfully
- Restart the Backblaze service

### SMB share not accessible
- Test access: `Test-Path "\\server\share"`
- Check firewall rules
- Verify credentials on the NAS/server

---

## Why This Works

The root cause is that Windows SYSTEM account has special security restrictions when accessing network resources. By running Backblaze under a regular local admin account:

1. The account can properly authenticate to SMB shares
2. File ownership/permissions work correctly
3. Dokan presents the network path as a local filesystem that Backblaze recognizes

---

## Tested With

- Windows 11
- Dokan 2.3.1
- Backblaze Personal (December 2024)
- Unraid SMB shares

---

## Disclaimer

This is an unofficial workaround. Use at your own risk. Not affiliated with or endorsed by Backblaze.

## License

MIT - See [LICENSE](LICENSE)
