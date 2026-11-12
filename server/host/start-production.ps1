# Run Solaris for real on the host laptop (Windows): MQTT broker, Ollama, and the API + landing page + APK on :8000.
# Run via start-production.bat. Ctrl+C (or closing the window) stops everything it started.
#
#   start-production.bat            normal start
#   start-production.bat -Update    git pull first (new APK, new code), then reinstall Python packages
#   start-production.bat -NoAI      don't start Ollama (Mira answers with the rule-based fallback)
#
# What "production" adds over start-windows.bat: checks before starting, the website and APK on the same port,
# the server restarts itself if it crashes, logs go to server\logs\server.log, and the laptop doesn't sleep.
param([switch]$Update, [switch]$NoAI, [int]$Port = 8000)

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")   # -> server\
$Repo = (Resolve-Path "..").Path
New-Item -ItemType Directory -Force logs | Out-Null
$Log = Join-Path $PWD "logs\server.log"
$Py = ".\.venv\Scripts\python.exe"

function Step($t) { Write-Host "== $t" -ForegroundColor Cyan }
function Warn($t) { Write-Host "   ! $t" -ForegroundColor Yellow }

# ------------------------------------------------------------------ checks --
if ($Update) {
  Step "Updating from git"
  & git -C $Repo pull --ff-only
  if ($LASTEXITCODE -ne 0) { Warn "git pull failed (local changes?). Starting with what is here." }
}

if (-not (Test-Path $Py)) {
  Write-Host "Python env missing. Run setup-windows.bat once first." -ForegroundColor Red
  Read-Host "Press Enter to close"; exit 1
}
if ($Update) { Step "Python packages"; & $Py -m pip install -q -r requirements.txt }
if (-not (Test-Path ".env")) { Copy-Item ".env.example" ".env"; Warn "created server\.env from .env.example" }

if (Select-String -Path ".env" -Pattern '^\s*SOLARIS_MOCK\s*=\s*1' -Quiet) {
  Warn "SOLARIS_MOCK=1 in server\.env: the app will show example data, not the device. Set it to 0 for the real demo."
}
if (-not (Test-Path "solaris.db")) { Step "No database yet: seeding 45 days of demo history"; & $Py tools\seed_history.py }

$apk = Join-Path $Repo "landing\downloads\solaris.apk"
if (Test-Path $apk) {
  $mb = [math]::Round((Get-Item $apk).Length / 1MB)
  Step "APK found: landing\downloads\solaris.apk ($mb MB)"
} else {
  Warn "No APK at landing\downloads\solaris.apk. The page still works; the download button says it's missing. Pull the repo (-Update)."
}

$inUse = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($inUse) {
  $p = Get-Process -Id ($inUse | Select-Object -First 1).OwningProcess -ErrorAction SilentlyContinue
  Write-Host "Port $Port is already used by $($p.ProcessName) (PID $($p.Id)). Close it (another start window?) and run again." -ForegroundColor Red
  Read-Host "Press Enter to close"; exit 1
}

# ---------------------------------------------------------------- services --
$mosqProc = $null
if (Get-NetTCPConnection -LocalPort 1883 -State Listen -ErrorAction SilentlyContinue) {
  Step "MQTT broker already running on :1883"
} else {
  $mosq = "C:\Program Files\mosquitto\mosquitto.exe"
  if (-not (Test-Path $mosq)) { Write-Host "Mosquitto not installed. Run setup-windows.bat." -ForegroundColor Red; Read-Host "Press Enter to close"; exit 1 }
  Step "Starting MQTT broker on :1883"
  $mosqProc = Start-Process $mosq -ArgumentList "-c", "`"$PWD\mosquitto.conf`"", "-v" -NoNewWindow -PassThru `
    -RedirectStandardError "logs\mosquitto.log"
}

if (-not $NoAI) {
  if (Get-Command ollama -ErrorAction SilentlyContinue) {
    if (-not (Get-Process ollama -ErrorAction SilentlyContinue)) {
      Step "Starting Ollama"; Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden; Start-Sleep 3
    }
    $model = "qwen3.5:9b"
    $m = Select-String -Path ".env" -Pattern '^\s*LLM_MODEL\s*=\s*(\S+)' | Select-Object -First 1
    if ($m) { $model = $m.Matches[0].Groups[1].Value }
    $ErrorActionPreference = "Continue"   # PowerShell 5.1 turns a native command's stderr into errors
    $have = (& ollama list 2>&1 | Out-String)
    $ErrorActionPreference = "Stop"
    if ($have -notmatch [regex]::Escape($model)) { Warn "Ollama model $model is not pulled: run  ollama pull $model  (Mira falls back to rule-based answers)." }
    else { Step "Ollama ready with $model" }
  } else { Warn "Ollama not installed: Mira answers with rule-based replies. setup-windows.bat installs it." }
}

# Keep the laptop awake while this window is open (released when it closes; no power settings are changed).
Add-Type -Namespace Solaris -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
[void][Solaris.Power]::SetThreadExecutionState([uint32]2147483651)   # 0x80000003: CONTINUOUS | SYSTEM_REQUIRED | DISPLAY_REQUIRED

# ------------------------------------------------------------------ banner --
$cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" } | Select-Object -First 1
$ip = if ($cfg) { $cfg.IPv4Address.IPAddress | Select-Object -First 1 } else {
  (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
   Select-Object -First 1).IPAddress }
Write-Host ""
Write-Host "  Solaris is running (production)" -ForegroundColor Green
Write-Host "  ------------------------------------------------------------"
Write-Host "  Website       http://${ip}:$Port/"
Write-Host "  Android app   http://${ip}:$Port/apk"
Write-Host "  In the app    Settings > server address:  ${ip}:$Port"
Write-Host "  API docs      http://${ip}:$Port/docs"
Write-Host "  MQTT broker   ${ip}:1883   (firmware: MQTT_MDNS_HOST `"$env:COMPUTERNAME`", MQTT_HOST `"$ip`")"
Write-Host "  Logs          server\logs\server.log, server\logs\mosquitto.log"
Write-Host "  Phones must be on the same Wi-Fi / hotspot as this laptop."
Write-Host "  Ctrl+C to stop"
Write-Host "  ------------------------------------------------------------"
Write-Host ""

# -------------------------------------------------------------- run + restart --
$env:PYTHONUNBUFFERED = "1"
try {
  while ($true) {
    "`n===== $(Get-Date -Format s) server start =====" | Out-File -Append -Encoding utf8 $Log
    $ErrorActionPreference = "Continue"   # uvicorn logs on stderr; don't treat that as a script error
    & $Py -m uvicorn app.main:app --host 0.0.0.0 --port $Port --proxy-headers --timeout-graceful-shutdown 5 2>&1 |
      ForEach-Object { $line = "$_"; Write-Host $line; Add-Content -Path $Log -Value $line -Encoding utf8 }
    $code = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    Write-Host "Server stopped (exit $code). Restarting in 3 s... (Ctrl+C to quit)" -ForegroundColor Yellow
    Start-Sleep 3
  }
} finally {
  [void][Solaris.Power]::SetThreadExecutionState([uint32]2147483648)   # 0x80000000: CONTINUOUS only = allow sleep again
  if ($mosqProc -and -not $mosqProc.HasExited) { Stop-Process -Id $mosqProc.Id -Force }
}
