@echo off
REM Dormant PC with AI - DAY mode: screen dimmed (not off), RGB off, PC stays awake.
REM The agent can always see the screen; nothing flashes.
start "Dormant PC with AI (Day)" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\DormantPC.ps1" -ScreenMode Dim %*
