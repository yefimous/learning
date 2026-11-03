#Requires -Version 5.1
<#
.SYNOPSIS
    Отправляет файл на 149.104.76.115 в /home/baby по SCP.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\send.ps1
#>
[CmdletBinding()]
param(
    [string] $LocalFile  = 'C:\Users\user1\Documents\50988aa7_5GB.dat.dat',
    [string] $RemoteHost = '149.104.76.115',
    [string] $RemoteUser = 'root',
    [string] $RemoteDir  = '/home/baby',
    [string] $Password   = 'dde-703-45-a-aA!',
    [int]    $Port       = 22
)

$ErrorActionPreference = 'Stop'
$RemoteDir  = $RemoteDir.TrimEnd('/')
$Leaf       = Split-Path -Leaf $LocalFile
$RemoteFile = "$RemoteDir/$Leaf"

if (-not (Test-Path -LiteralPath $LocalFile -PathType Leaf)) {
    throw "Файл не найден: $LocalFile"
}
$LocalSize = (Get-Item -LiteralPath $LocalFile).Length

Write-Host "Отправляю $LocalFile -> ${RemoteUser}@${RemoteHost}:$RemoteFile"

$done = $false

# --- вариант 1: Posh-SSH (пароль передаётся через credential, без интерактива) ---
function Ensure-PoshSSH {
    if (Get-Module -ListAvailable -Name Posh-SSH) { return $true }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
        }
        Install-Module Posh-SSH -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        return $true
    } catch {
        Write-Host "Posh-SSH не установился: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $false
    }
}

if (Ensure-PoshSSH) {
    try {
        Import-Module Posh-SSH -ErrorAction Stop
        $sec  = ConvertTo-SecureString $Password -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($RemoteUser, $sec)

        $sess = New-SSHSession -ComputerName $RemoteHost -Port $Port -Credential $cred -AcceptKey -ErrorAction Stop
        try {
            Set-SCPItem -Path $LocalFile -Destination $RemoteDir -ComputerName $RemoteHost -Port $Port `
                        -Credential $cred -AcceptKey -PathType Directory -ErrorAction Stop | Out-Null

            $out = (Invoke-SSHCommand -SessionId $sess.SessionId -Command "stat -c %s '$RemoteFile'" -ErrorAction Stop).Output -join ''
            $remoteSize = 0L
            [void][int64]::TryParse($out.Trim(), [ref]$remoteSize)
            if ($remoteSize -ne $LocalSize) {
                throw "Размер на сервере ($remoteSize) не совпал с локальным ($LocalSize)"
            }
            $done = $true
        } finally {
            if ($sess) { Remove-SSHSession -SessionId $sess.SessionId -ErrorAction SilentlyContinue | Out-Null }
        }
    } catch {
        Write-Host "Posh-SSH: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# --- вариант 2: pscp из PuTTY ---
if (-not $done -and (Get-Command pscp.exe -ErrorAction SilentlyContinue)) {
    try {
        & pscp.exe -batch -q -P $Port -pw $Password $LocalFile "${RemoteUser}@${RemoteHost}:$RemoteDir/"
        if ($LASTEXITCODE -ne 0) { throw "pscp завершился с кодом $LASTEXITCODE" }
        $done = $true
    } catch {
        Write-Host "pscp: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# --- вариант 3: нативный scp + SSH_ASKPASS ---
if (-not $done -and (Get-Command scp.exe -ErrorAction SilentlyContinue)) {
    $ask = Join-Path $env:TEMP ('askpass_{0}.cmd' -f ([guid]::NewGuid().ToString('N')))
    Set-Content -LiteralPath $ask -Value "@echo off`r`necho $Password" -Encoding ASCII
    $oldAsk = $env:SSH_ASKPASS; $oldReq = $env:SSH_ASKPASS_REQUIRE
    $env:SSH_ASKPASS = $ask; $env:SSH_ASKPASS_REQUIRE = 'force'
    try {
        & scp.exe -q -P $Port -o StrictHostKeyChecking=accept-new -o NumberOfPasswordPrompts=1 `
                  $LocalFile "${RemoteUser}@${RemoteHost}:$RemoteDir/"
        if ($LASTEXITCODE -ne 0) { throw "scp завершился с кодом $LASTEXITCODE" }
        $done = $true
    } catch {
        Write-Host "scp: $($_.Exception.Message)" -ForegroundColor DarkYellow
    } finally {
        $env:SSH_ASKPASS = $oldAsk; $env:SSH_ASKPASS_REQUIRE = $oldReq
        Remove-Item -LiteralPath $ask -Force -ErrorAction SilentlyContinue
    }
}

if (-not $done) {
    throw 'Доставка не удалась. Поставьте Posh-SSH: Install-Module Posh-SSH -Scope CurrentUser'
}

Write-Host "[OK] Файл на сервере: $RemoteFile ($LocalSize байт)" -ForegroundColor Green
