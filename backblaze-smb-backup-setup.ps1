#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Setup script for backing up SMB/Network shares with Backblaze Personal using Dokan.

.DESCRIPTION
    Backblaze Personal runs as SYSTEM by default, which cannot create files on SMB shares
    (error 1307 - invalid owner). This script:
    1. Creates a local user account for Backblaze
    2. Grants "Log on as a service" right to that account
    3. Configures the Backblaze service to run under that account
    4. Creates a scheduled task to mount the SMB share via Dokan's mirror.exe

.NOTES
    Prerequisites:
    - Dokan Library 2.x installed (https://github.com/dokan-dev/dokany/releases)
    - Backblaze Personal installed
    - Admin privileges

.EXAMPLE
    .\backblaze-smb-backup-setup.ps1 -SMBPath "\\192.168.3.188\share" -DriveLetter "X" -Password "YourSecurePassword123!"

.EXAMPLE
    .\backblaze-smb-backup-setup.ps1 -SMBPath "\\192.168.3.188\share" -DriveLetter "X" -Password "YourSecurePassword123!" -NASUser "tom" -NASPassword "naspass123"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SMBPath,

    [Parameter(Mandatory=$true)]
    [string]$DriveLetter,

    [Parameter(Mandatory=$false)]
    [string]$Username = "BackblazeUser",

    [Parameter(Mandatory=$true)]
    [string]$Password,

    [Parameter(Mandatory=$false)]
    [string]$NASUser,

    [Parameter(Mandatory=$false)]
    [string]$NASPassword,

    [Parameter(Mandatory=$false)]
    [string]$DokanPath = "C:\Program Files\Dokan\Dokan Library-2.3.1\sample\mirror\mirror.exe"
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Backblaze SMB Backup Setup Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Verify Dokan is installed
if (-not (Test-Path $DokanPath)) {
    Write-Host "ERROR: Dokan mirror.exe not found at: $DokanPath" -ForegroundColor Red
    Write-Host "Please install Dokan from: https://github.com/dokan-dev/dokany/releases" -ForegroundColor Yellow
    exit 1
}
Write-Host "[OK] Dokan found at: $DokanPath" -ForegroundColor Green

# Verify SMB path is accessible
Write-Host "Testing SMB path connectivity..." -ForegroundColor Yellow
if (-not (Test-Path $SMBPath -ErrorAction SilentlyContinue)) {
    Write-Host "WARNING: Cannot access SMB path: $SMBPath" -ForegroundColor Yellow
    Write-Host "Make sure the network share is accessible and try again." -ForegroundColor Yellow
    $continue = Read-Host "Continue anyway? (y/n)"
    if ($continue -ne "y") { exit 1 }
} else {
    Write-Host "[OK] SMB path accessible: $SMBPath" -ForegroundColor Green
}

# Step 1: Create local user account
Write-Host ""
Write-Host "Step 1: Creating local user account '$Username'..." -ForegroundColor Cyan

$userExists = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
if ($userExists) {
    Write-Host "[OK] User '$Username' already exists" -ForegroundColor Green
} else {
    try {
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        New-LocalUser -Name $Username -Password $securePassword -PasswordNeverExpires -UserMayNotChangePassword -Description "Service account for Backblaze backup"
        Add-LocalGroupMember -Group "Administrators" -Member $Username
        Write-Host "[OK] Created local admin user: $Username" -ForegroundColor Green
    } catch {
        Write-Host "ERROR: Failed to create user: $_" -ForegroundColor Red
        exit 1
    }
}

# Step 1b: Grant "Log on as a service" right
Write-Host ""
Write-Host "Step 1b: Granting 'Log on as a service' right to '$Username'..." -ForegroundColor Cyan

try {
    $tempFile = [System.IO.Path]::GetTempFileName()
    $tempDb = [System.IO.Path]::GetTempFileName()

    # Export current security policy
    secedit /export /cfg $tempFile | Out-Null

    # Get user SID
    $userSid = (New-Object System.Security.Principal.NTAccount($Username)).Translate([System.Security.Principal.SecurityIdentifier]).Value

    # Read config and add user to SeServiceLogonRight
    $config = Get-Content $tempFile
    $newConfig = @()
    $found = $false

    foreach ($line in $config) {
        if ($line -match "^SeServiceLogonRight") {
            $found = $true
            if ($line -notmatch $userSid) {
                $line = $line + ",*$userSid"
            }
        }
        $newConfig += $line
    }

    # If SeServiceLogonRight wasn't found, add it
    if (-not $found) {
        $newConfig += "SeServiceLogonRight = *$userSid"
    }

    Set-Content $tempFile $newConfig

    # Apply the new policy
    secedit /configure /db $tempDb /cfg $tempFile /areas USER_RIGHTS | Out-Null

    # Cleanup
    Remove-Item $tempFile -ErrorAction SilentlyContinue
    Remove-Item $tempDb -ErrorAction SilentlyContinue
    Remove-Item "$tempDb.log" -ErrorAction SilentlyContinue
    Remove-Item "$tempDb.jfm" -ErrorAction SilentlyContinue

    Write-Host "[OK] Granted 'Log on as a service' right to $Username" -ForegroundColor Green
} catch {
    Write-Host "WARNING: Could not automatically grant 'Log on as a service' right: $_" -ForegroundColor Yellow
    Write-Host "You may need to manually add this in secpol.msc > Local Policies > User Rights Assignment" -ForegroundColor Yellow
}

# Step 2: Configure Backblaze service
Write-Host ""
Write-Host "Step 2: Configuring Backblaze service to run as '$Username'..." -ForegroundColor Cyan

$bbService = Get-Service -Name "bzserv" -ErrorAction SilentlyContinue
if (-not $bbService) {
    Write-Host "ERROR: Backblaze service 'bzserv' not found. Is Backblaze installed?" -ForegroundColor Red
    exit 1
}

# Stop service first
if ($bbService.Status -eq "Running") {
    Write-Host "Stopping Backblaze service..." -ForegroundColor Yellow
    Stop-Service -Name "bzserv" -Force
    Start-Sleep -Seconds 2
}

# Configure service account
$scResult = & sc.exe config "bzserv" obj= ".\$Username" password= "$Password" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to configure service: $scResult" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Backblaze service configured to run as .\$Username" -ForegroundColor Green

# Start service
Write-Host "Starting Backblaze service..." -ForegroundColor Yellow
Start-Service -Name "bzserv"
Write-Host "[OK] Backblaze service started" -ForegroundColor Green

# Step 3: Create scheduled task for Dokan mirror
Write-Host ""
Write-Host "Step 3: Creating scheduled task for Dokan mount..." -ForegroundColor Cyan

$taskName = "DokanMirror-$DriveLetter"
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($existingTask) {
    Write-Host "Removing existing scheduled task..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# Create the scheduled task using a batch file wrapper for reliable path handling
$batchDir = "C:\ProgramData\DokanMount"
if (-not (Test-Path $batchDir)) {
    New-Item -ItemType Directory -Path $batchDir | Out-Null
}
$batchFile = "$batchDir\mount-$DriveLetter.bat"
# /g flag makes the mount global (visible to all users)
# Include net use with credentials if NAS credentials were provided
if ($NASUser -and $NASPassword) {
    $batchContent = "@echo off`r`nnet use `"$SMBPath`" /user:$NASUser $NASPassword`r`n`"$DokanPath`" /r `"$SMBPath`" /l $DriveLetter /g"
} else {
    $batchContent = "@echo off`r`n`"$DokanPath`" /r `"$SMBPath`" /l $DriveLetter /g"
}
Set-Content -Path $batchFile -Value $batchContent -Encoding ASCII
Write-Host "[OK] Created batch file: $batchFile" -ForegroundColor Green

$schtasksResult = & schtasks.exe /Create /TN "$taskName" /TR "`"$batchFile`"" /SC ONSTART /RU "$Username" /RP "$Password" /RL HIGHEST /F 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to create scheduled task: $schtasksResult" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Created scheduled task: $taskName" -ForegroundColor Green

# Step 4: Start the mount now
Write-Host ""
Write-Host "Step 4: Starting Dokan mount now..." -ForegroundColor Cyan

# Check if drive is already mounted
$driveExists = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
if ($driveExists) {
    Write-Host "[OK] Drive $DriveLetter`: is already mounted" -ForegroundColor Green
} else {
    Write-Host "Starting scheduled task to mount drive..." -ForegroundColor Yellow
    & schtasks.exe /Run /TN $taskName | Out-Null
    Start-Sleep -Seconds 3

    $driveExists = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
    if ($driveExists) {
        Write-Host "[OK] Drive $DriveLetter`: mounted successfully" -ForegroundColor Green
    } else {
        Write-Host "WARNING: Drive may take a moment to appear. Check manually." -ForegroundColor Yellow
    }
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor White
Write-Host "  - Local user created: $Username" -ForegroundColor White
Write-Host "  - Backblaze service running as: .\$Username" -ForegroundColor White
Write-Host "  - SMB path: $SMBPath" -ForegroundColor White
Write-Host "  - Mounted as: $DriveLetter`:" -ForegroundColor White
Write-Host "  - Scheduled task: $taskName (runs at startup)" -ForegroundColor White
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. Open Backblaze settings" -ForegroundColor White
Write-Host "  2. Go to 'Settings' > 'Hard Drives'" -ForegroundColor White
Write-Host "  3. Check the box next to drive $DriveLetter`:" -ForegroundColor White
Write-Host "  4. Wait for initial scan to complete" -ForegroundColor White
Write-Host ""
Write-Host "Troubleshooting:" -ForegroundColor Yellow
Write-Host "  - If drive doesn't appear, run: schtasks /Run /TN '$taskName'" -ForegroundColor White
Write-Host "  - Check Dokan logs in Event Viewer > Applications" -ForegroundColor White
Write-Host "  - Verify SMB share is accessible from this machine" -ForegroundColor White
