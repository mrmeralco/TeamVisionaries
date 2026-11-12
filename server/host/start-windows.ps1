# Start the Sinag host on Windows: Mosquitto on :1883 + FastAPI on :8000. Ctrl+C stops both.
# Run via start-windows.bat (no admin needed).
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")   # -> server\
New-Item -ItemType Directory -Force logs | Out-Null

$mosqProc = $null
if (Get-NetTCPConnection -LocalPort 1883 -State Listen -ErrorAction SilentlyContinue) {
  Write-Host "Port 1883 already in use, assuming a broker is running."
} else {
  $mosqProc = Start-Process "C:\Program Files\mosquitto\mosquitto.exe" `
    -ArgumentList "-c", "`"$PWD\mosquitto.conf`"", "-v" -NoNewWindow -PassThru `
    -RedirectStandardError "logs\mosquitto.log"
}

if ((Get-Command ollama -ErrorAction SilentlyContinue) -and -not (Get-Process ollama -ErrorAction SilentlyContinue)) {
  Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden
}

$ip = (Get-NetIPAddress -AddressFamily IPv4 |
       Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.PrefixOrigin -ne "WellKnown" } |
       Select-Object -First 1).IPAddress
Write-Host ""
Write-Host "  Sinag host is up"
Write-Host "  -----------------------------------------------"
Write-Host "  MQTT broker   ${ip}:1883     (log: server\logs\mosquitto.log)"
Write-Host "  API + docs    http://${ip}:8000/docs"
Write-Host "  Firmware      in firmware\sinag-device\config.h set"
Write-Host "                MQTT_MDNS_HOST `"$env:COMPUTERNAME`"  (finds this laptop on any IP)"
Write-Host "                MQTT_HOST `"$ip`"  (fallback)"
Write-Host "  Ctrl+C to stop"
Write-Host "  -----------------------------------------------"
Write-Host ""

try {
  .\.venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000
} finally {
  if ($mosqProc -and -not $mosqProc.HasExited) { Stop-Process -Id $mosqProc.Id -Force }
}
