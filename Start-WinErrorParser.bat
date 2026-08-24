@echo off
setlocal EnableExtensions
set "ERR=0"

REM Keep this .bat as ASCII / ANSI WITHOUT UTF-8 BOM.
REM (UTF-8 BOM breaks cmd.exe and the window closes immediately.)
cd /d "%~dp0"
title WinErrorParser

echo ============================================================
echo   WinErrorParser - Windows diagnostics
echo ============================================================
echo.
echo Folder: %CD%
echo.

where powershell >nul 2>&1
if errorlevel 1 (
    echo [ERROR] PowerShell not found in PATH.
    set "ERR=1"
    goto :finish
)

if not exist "%~dp0WinErrorParser.ps1" (
    echo [ERROR] WinErrorParser.ps1 not found in this folder:
    echo         %~dp0
    set "ERR=1"
    goto :finish
)

REM Request admin: re-launch this bat elevated, then close this window.
net session >nul 2>&1
if errorlevel 1 (
    echo [INFO] Administrator rights required. Showing UAC prompt...
    echo.
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -LiteralPath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
    if errorlevel 1 (
        echo [ERROR] UAC elevation failed.
        echo Right-click this .bat -^> Run as administrator.
        set "ERR=1"
        goto :finish
    )
    exit /b 0
)

echo [OK] Running as administrator.
echo.

REM Check UTF-8 BOM on the .ps1 (required by Windows PowerShell 5.1)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p = Join-Path -Path '%~dp0' -ChildPath 'WinErrorParser.ps1'; $b = [System.IO.File]::ReadAllBytes($p); if ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { Write-Host '[ERROR] WinErrorParser.ps1 must be UTF-8 with BOM. Re-download from GitHub.' -ForegroundColor Red; exit 2 }; exit 0"
if errorlevel 1 (
    echo [ERROR] WinErrorParser.ps1 encoding check failed.
    set "ERR=2"
    goto :finish
)

echo Starting diagnostics. Please wait...
echo.

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinErrorParser.ps1"
set "ERR=%ERRORLEVEL%"

echo.
if not "%ERR%"=="0" (
    echo [ERROR] Script exited with code %ERR%.
) else (
    echo [OK] Finished.
    echo Report: %~dp0WinErrorParser_Report_RU.txt
)

:finish
echo.
echo Press any key to close this window...
pause >nul
endlocal & exit /b %ERR%
