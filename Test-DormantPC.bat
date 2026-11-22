@echo off
REM Dormant PC with AI - self-test. Writes DormantPC-selftest.log next to this file.
REM Add -SkipVisualTests to skip the screen/RGB blackout checks.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\DormantPC.ps1" -SelfTest %*
echo.
pause
