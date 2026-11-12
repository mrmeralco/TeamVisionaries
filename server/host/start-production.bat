@echo off
rem Solaris production start: broker + Ollama + API, website and APK on :8000. Options: -Update  -NoAI
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-production.ps1" %*
pause
