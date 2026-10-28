#requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

function Ask-NonEmpty([string]$Prompt) {
    do { $value = (Read-Host $Prompt).Trim() } while ([string]::IsNullOrWhiteSpace($value))
    return $value
}

function Write-Step([string]$Message) {
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Find-CloudflaredExe {
    $candidates = @(
        "C:\Cloudflared\bin\cloudflared.exe",
        "C:\Program Files\cloudflared\cloudflared.exe",
        "C:\Program Files (x86)\cloudflared\cloudflared.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $command = Get-Command cloudflared -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { return $command.Source }
    return $null
}

function Find-TunnelIdByName([string]$Exe, [string]$Name) {
    $listing = (& $Exe tunnel list 2>&1 | Out-String)
    $escapedName = [regex]::Escape($Name)
    $match = [regex]::Match($listing, "(?im)^\s*([0-9a-fA-F-]{36})\s+$escapedName(?:\s|$)")
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Require-NativeSuccess([string]$Action) {
    if ($LASTEXITCODE -ne 0) { throw "$Action ไม่สำเร็จ (exit code $LASTEXITCODE)" }
}

Write-Host "Cloudflare Tunnel - Windows setup" -ForegroundColor Yellow

Write-Step "ตรวจสอบและติดตั้ง cloudflared"
$foundExe = Find-CloudflaredExe
if (-not $foundExe) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "ไม่พบ cloudflared หรือ winget กรุณาติดตั้ง App Installer/winget แล้วรันใหม่"
    }
    & $winget.Source install --id Cloudflare.cloudflared --exact --accept-package-agreements --accept-source-agreements --silent
    Start-Sleep -Seconds 3
    $foundExe = Find-CloudflaredExe
    if (-not $foundExe) { throw "ติดตั้งแล้วแต่หา cloudflared.exe ไม่พบ กรุณาติดตั้งจาก Cloudflare Downloads แล้วรันใหม่" }
}

$rootDir = "C:\Cloudflared"
$binDir = Join-Path $rootDir "bin"
$serviceDir = "C:\Windows\System32\config\systemprofile\.cloudflared"
$logFile = Join-Path $rootDir "cloudflared.log"
$configPath = Join-Path $serviceDir "config.yml"
$serviceExe = Join-Path $binDir "cloudflared.exe"
$serviceRegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Cloudflared"

New-Item -ItemType Directory -Force -Path $binDir, $serviceDir | Out-Null
if ([IO.Path]::GetFullPath($foundExe) -ne [IO.Path]::GetFullPath($serviceExe)) {
    Copy-Item -LiteralPath $foundExe -Destination $serviceExe -Force
}

Write-Step "ข้อมูล Tunnel และ origin"
$tunnelName = Ask-NonEmpty "Tunnel name (เช่น my-win-tunnel)"
$hostname = Ask-NonEmpty "Domain ใน Cloudflare (เช่น app.example.com)"
$originHost = Ask-NonEmpty "Origin host: localhost, IP หรือ hostname"
$originPortText = Ask-NonEmpty "Origin port (1-65535)"

if ($tunnelName -notmatch '^[A-Za-z0-9_-]+$') { throw "Tunnel name ใช้ได้เฉพาะตัวอักษร ตัวเลข _ และ -" }
if ($hostname -notmatch '^(?=.{1,253}$)(?!-)[A-Za-z0-9.-]+(?<!-)$' -or $hostname.Contains("..")) { throw "Domain ไม่ถูกต้อง" }
if ($originHost -notmatch '^[A-Za-z0-9.-]+$' -or $originHost.Contains("..")) { throw "Origin host ให้ใส่ localhost, IP หรือ hostname โดยไม่ใส่ scheme/port" }
$originPort = 0
if (-not [int]::TryParse($originPortText, [ref]$originPort) -or $originPort -lt 1 -or $originPort -gt 65535) { throw "Port ต้องเป็นตัวเลข 1-65535" }

$scheme = "http"
$noTlsVerify = $false
if ((Read-Host "Origin ใช้ HTTPS ไหม? (y/N)") -match '^(y|Y)$') {
    $scheme = "https"
    if ((Read-Host "Origin ใช้ self-signed certificate ไหม? (y/N)") -match '^(y|Y)$') { $noTlsVerify = $true }
}
$originService = "${scheme}://${originHost}:${originPort}"

$userCloudflaredDir = Join-Path $env:USERPROFILE ".cloudflared"
New-Item -ItemType Directory -Force -Path $userCloudflaredDir | Out-Null
$certPem = Join-Path $userCloudflaredDir "cert.pem"
if (-not (Test-Path -LiteralPath $certPem)) {
    Write-Step "เข้าสู่ระบบ Cloudflare"
    Write-Host "เบราว์เซอร์จะเปิดขึ้น ให้ authorize zone ที่ต้องการใช้" -ForegroundColor Yellow
    & $serviceExe tunnel login
    Require-NativeSuccess "Cloudflare login"
}
if (-not (Test-Path -LiteralPath $certPem)) { throw "ไม่พบ cert.pem ที่ $certPem หลัง login" }

Write-Step "สร้างหรือใช้ Tunnel"
$tunnelId = Find-TunnelIdByName $serviceExe $tunnelName
if (-not $tunnelId) {
    & $serviceExe tunnel create $tunnelName
    Require-NativeSuccess "สร้าง Tunnel"
    $tunnelId = Find-TunnelIdByName $serviceExe $tunnelName
}
if (-not $tunnelId) { throw "หา Tunnel ID ไม่พบ ตรวจสอบด้วยคำสั่ง: `"$serviceExe`" tunnel list" }

$userCredentialPath = Join-Path $userCloudflaredDir "$tunnelId.json"
if (-not (Test-Path -LiteralPath $userCredentialPath)) { throw "ไม่พบ credentials file: $userCredentialPath" }
$serviceCredentialPath = Join-Path $serviceDir "$tunnelId.json"
Copy-Item -LiteralPath $certPem -Destination (Join-Path $serviceDir "cert.pem") -Force
Copy-Item -LiteralPath $userCredentialPath -Destination $serviceCredentialPath -Force

Write-Step "กำหนด DNS และสร้าง config"
& $serviceExe tunnel route dns $tunnelId $hostname
Require-NativeSuccess "ผูก DNS route"

if (Test-Path -LiteralPath $configPath) {
    $backupPath = "$configPath.$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').bak"
    Copy-Item -LiteralPath $configPath -Destination $backupPath
    Write-Host "สำรอง config เดิม: $backupPath"
}

$tlsConfig = if ($noTlsVerify) { "`noriginRequest:`n  noTLSVerify: true" } else { "" }
$config = @"
tunnel: $tunnelId
credentials-file: $serviceCredentialPath
$tlsConfig
ingress:
  - hostname: $hostname
    service: $originService
  - service: http_status:404

logfile: $logFile
"@
$temporaryConfigPath = "$configPath.tmp"
Set-Content -LiteralPath $temporaryConfigPath -Value $config -Encoding ASCII
& $serviceExe tunnel --config $temporaryConfigPath ingress validate
Require-NativeSuccess "ตรวจ ingress config"
Move-Item -LiteralPath $temporaryConfigPath -Destination $configPath -Force

# Restrict tunnel credentials to Local System and local Administrators.
& icacls.exe $serviceDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "กำหนด ACL ให้โฟลเดอร์ credentials ไม่สำเร็จ" }

Write-Step "ติดตั้งและเริ่ม Windows service"
$service = Get-Service -Name cloudflared -ErrorAction SilentlyContinue
if (-not $service) {
    & $serviceExe service install
    Require-NativeSuccess "ติดตั้ง cloudflared service"
}
if (-not (Test-Path -LiteralPath $serviceRegistryPath)) { throw "ไม่พบ registry entry ของ service: $serviceRegistryPath" }
$imagePath = "`"$serviceExe`" --config=`"$configPath`" tunnel run"
Set-ItemProperty -LiteralPath $serviceRegistryPath -Name ImagePath -Value $imagePath
if ((Get-Service -Name cloudflared).Status -eq "Running") {
    Restart-Service -Name cloudflared
} else {
    Start-Service -Name cloudflared
}
Start-Sleep -Seconds 2
$service = Get-Service -Name cloudflared
if ($service.Status -ne "Running") { throw "cloudflared service ยังไม่ Running ตรวจสอบ log ที่ $logFile" }

Write-Step "ตั้งค่าเสร็จแล้ว"
Write-Host "Tunnel ID : $tunnelId" -ForegroundColor Green
Write-Host "Hostname  : $hostname" -ForegroundColor Green
Write-Host "Origin    : $originService" -ForegroundColor Green
Write-Host "Config    : $configPath" -ForegroundColor Green
Write-Host "Log       : $logFile" -ForegroundColor Green
Write-Host "ทดสอบเปิด: https://$hostname" -ForegroundColor Yellow
Write-Host "สถานะ: Get-Service cloudflared"
Write-Host "Log: Get-Content '$logFile' -Tail 100 -Wait"
