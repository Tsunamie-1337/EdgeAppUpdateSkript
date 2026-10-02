@echo off
setlocal
rem Startet DE-IEM-AppInstaller.ps1 mit PowerShell 7 und ExecutionPolicy Bypass
rem (gilt nur fuer diesen einen Prozess, Systemeinstellungen bleiben unveraendert).

rem Batch-Groesse (Geraete pro Batch, erlaubt: 1-100)
set BATCHSIZE=10

cd /d "%~dp0"

where pwsh >nul 2>&1
if errorlevel 1 (
    echo PowerShell 7 ^(pwsh^) wurde nicht gefunden. Bitte installieren:
    echo https://aka.ms/powershell
    pause
    exit /b 1
)

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0DE-IEM-AppInstaller.ps1" -BatchSize %BATCHSIZE% %*
set EXITCODE=%ERRORLEVEL%

pause
exit /b %EXITCODE%
