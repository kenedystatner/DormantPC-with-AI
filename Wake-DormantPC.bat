@echo off
REM Dormant PC with AI - end dormant mode (screen + RGB back on, normal sleep rules).
setlocal
set "PIDFILE=%TEMP%\DormantPC.pid"
set "DPID="
if exist "%PIDFILE%" set /p DPID=<"%PIDFILE%"
if defined DPID (
    tasklist /FI "PID eq %DPID%" 2>nul | find "%DPID%" >nul
    if not errorlevel 1 (
        echo stop> "%TEMP%\DormantPC.stop"
        echo Waking up - screen and lights will be back in a few seconds.
        timeout /t 4 >nul
        exit /b 0
    )
)
echo Dormant PC isn't running - forcing screens and lights back on anyway.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\DormantPC.ps1" -WakeOnly
timeout /t 3 >nul
