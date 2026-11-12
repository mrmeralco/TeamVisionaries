# One-time setup of the Solaris host on Windows 10/11: Mosquitto broker, Python env, .env,
# firewall rules, demo history, AI model. Run via setup-windows.bat (asks for admin).
#   setup-windows.bat            everything
#   setup-windows.bat -SkipAI    no Ollama model download (3.3 GB)
param([switch]$SkipAI)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")   # -> server\

function Need-Winget { if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw "winget not found. Install 'App Installer' from the Microsoft Store, then run this again." } }
function Refresh-Path { $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                                    [Environment]::GetEnvironmentVariable("Path","User") }

Write-Host "== Mosquitto (MQTT broker)"
$mosq = "C:\Program Files\mosquitto\mosquitto.exe"
if (-not (Test-Path $mosq)) {
  Need-Winget
  winget install -e --id EclipseFoundation.Mosquitto --accept-package-agreements --accept-source-agreements
}
# The installer adds a Windows service that only listens on localhost. We run our own copy
# with server\mosquitto.conf (open on the LAN), so stop and disable the service.
if (Get-Service mosquitto -ErrorAction SilentlyContinue) {
  Stop-Service mosquitto -ErrorAction SilentlyContinue
  Set-Service mosquitto -StartupType Disabled
}

Write-Host "== Firewall: allow ESP32 and phones to reach 1883 (MQTT) and 8000 (API)"
foreach ($p in 1883, 8000) {
  $name = "Solaris $p"
  if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $p `
      -Action Allow -Profile Private,Public | Out-Null
  }
}

Write-Host "== Python"
$py = Get-Command py -ErrorAction SilentlyContinue
if (-not $py) {
  Need-Winget
  winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
  Refresh-Path
}
if (-not (Test-Path ".venv")) { py -3 -m venv .venv }
.\.venv\Scripts\python.exe -m pip install -q --upgrade pip
.\.venv\Scripts\python.exe -m pip install -q -r requirements.txt

Write-Host "== server\.env"
if (-not (Test-Path ".env")) { Copy-Item ".env.example" ".env" }

Write-Host "== Demo history (45 days)"
if (-not (Test-Path "solaris.db")) { .\.venv\Scripts\python.exe tools\seed_history.py }

if (-not $SkipAI) {
  Write-Host "== AI model (Ollama)"
  if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Need-Winget
    winget install -e --id Ollama.Ollama --accept-package-agreements --accept-source-agreements
    Refresh-Path
  }
  $model = (Select-String -Path ".env" -Pattern '^LLM_MODEL=(.+)$').Matches.Groups[1].Value
  if (-not $model) { $model = "qwen3.5:4b" }
  ollama pull $model
}

Write-Host ""
Write-Host "Setup done. Start everything with:  server\host\start-windows.bat"
