@echo off
rem ===================================================================
rem  WTA301 kit launcher
rem
rem  Two hard rules for this file:
rem
rem  1) PURE ASCII ONLY. cmd.exe reads .bat using the OEM codepage
rem     (GBK on Chinese Windows), so UTF-8 Chinese here turns into
rem     mojibake and eats the next line -- e.g. "if errorlevel" got
rem     eaten to "rrorlevel". All Chinese text lives in wta301.ps1
rem     instead (that file has a UTF-8 BOM, so PowerShell reads it
rem     correctly).
rem
rem  2) NEVER call "where" or rely on PATH. On some machines "where"
rem     is missing/shadowed and fails with a parse error. We resolve
rem     powershell.exe by absolute path under %SystemRoot%.
rem ===================================================================
setlocal EnableExtensions
cd /d "%~dp0"

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PSEXE%" (
    echo.
    echo   [X] Windows PowerShell not found.
    echo       Expected at: %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
    echo       Windows 10 / 11 always ships it - please check your system.
    pause
    exit /b 1
)

net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo   Administrator rights required - asking now...
    echo   [elevation requested]
    "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "PS1=%~dp0wta301.ps1"
if not exist "%PS1%" (
    echo.
    echo   [X] wta301.ps1 not found next to this .bat
    echo       Expected: "%PS1%"
    echo       Copy the WHOLE kit folder, not just this .bat.
    pause
    exit /b 1
)

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo   [exit code %RC%]
    pause
)
endlocal
exit /b %RC%
