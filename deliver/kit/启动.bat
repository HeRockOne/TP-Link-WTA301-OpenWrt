@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions
cd /d "%~dp0"

rem ===================================================================
rem  WTA301 一键工具 —— 入口
rem  这个 bat 只做三件事：要管理员权限、确认 PowerShell 可用、把参数转给 ps1
rem  全部逻辑在 wta301.ps1 里（纯 PowerShell，Windows 10 自带，不需要装 Python）
rem ===================================================================

net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo   需要管理员权限，正在申请...  Asking for Administrator...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

where powershell >nul 2>&1
if errorlevel 1 (
    echo.
    echo   [X] 找不到 PowerShell。这个工具需要 Windows 自带的 PowerShell 5.1。
    echo       正常 Windows 10 / 11 都有。请检查系统是否被精简过。
    pause
    exit /b 1
)

set "PS1=%~dp0wta301.ps1"
if not exist "%PS1%" (
    echo.
    echo   [X] 找不到 wta301.ps1。请把整个目录一起拷走，不要只拷 .bat 文件。
    pause
    exit /b 1
)

echo.
echo   先跑一遍离线自检，确认文件齐全、密码学能跑...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -SelfTest
if errorlevel 1 (
    echo.
    echo   [X] 自检没通过，先修上面的问题再动设备。
    pause
    exit /b 1
)

echo.
set /p DEVIP=   设备 IP（直接回车 = 192.168.1.1）:
if "%DEVIP%"=="" set DEVIP=192.168.1.1

echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Target "%DEVIP%" %*

echo.
pause
