@echo off
chcp 65001 >nul
setlocal
set "HERE=%~dp0"
set "PKG=%~1"
if "%PKG%"=="" set /p "PKG=Local server folder (e.g. D:\Stella Sora): "
set "UID=%~2"
if "%UID%"=="" set /p "UID=Player UID (e.g. 10003): "
set "MODE=--send-mail"
if /i "%~3"=="dry" set "MODE=--dry"
set "JAVA=%PKG%\Server\Runtime\Java\bin\java.exe"
if not exist "%JAVA%" set "JAVA=java"
echo.
"%JAVA%" -Dstdout.encoding=UTF-8 -Dstderr.encoding=UTF-8 -cp "%HERE%;%PKG%\Server\lib\Nebula.jar" ActivityTaskFix --server "%PKG%" --uid %UID% %MODE%
echo.
pause
