@echo off
chcp 65001 >nul
setlocal
echo ============================================
echo  StellaSora Local Server - Client Update Fix
echo ============================================
echo.
echo This will update your local Nebula server to match
echo the current game client (jar + data + data version).
echo A full backup is created before any change.
echo.
set /p SERVERDIR=Server root folder (e.g. D:\Stella Sora):
if "%SERVERDIR%"=="" (
  echo No path given, exit.
  pause
  exit /b 1
)
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-client-update.ps1" -ServerDir "%SERVERDIR%"
echo.
pause
