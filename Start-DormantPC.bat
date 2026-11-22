@echo off
REM Dormant PC with AI - start dormant mode (PC stays awake, black overlay + brightness 0, RGB off).
REM Options pass through, e.g.:  Start-DormantPC.bat -MaxHours 8
start "Dormant PC with AI" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\DormantPC.ps1" %*
