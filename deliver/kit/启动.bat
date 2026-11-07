@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

rem ---- elevate to admin ----
net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo   需要管理员权限，正在申请...  Asking for Administrator...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set PYTHONIOENCODING=utf-8
set PYTHONUTF8=1

echo ============================================================
echo   WTA301 一键工具   (getroot / 刷机 / 备份 / 修回退槽)
echo ============================================================
echo   工作目录: %CD%
echo.

rem ---- check python ----
where python >nul 2>&1
if errorlevel 1 (
    echo   [X] 找不到 python。请安装 Python 3.8+ 并勾选 "Add to PATH"。
    echo       下载地址: https://www.python.org/downloads/
    goto :end
)
for /f "delims=" %%v in ('python -c "import sys;print(sys.version.split()[0])" 2^>nul') do set PYVER=%%v
echo   python %PYVER%

python -c "import cryptography" >nul 2>&1
if errorlevel 1 (
    echo.
    echo   [!] 缺少 cryptography，正在安装...
    python -m pip install --quiet cryptography
    python -c "import cryptography" >nul 2>&1
    if errorlevel 1 (
        echo   [X] 安装失败。请手动执行:  python -m pip install cryptography
        goto :end
    )
)
echo   cryptography OK

rem ---- check files (含 md5) ----
python wta301-getroot.py --check-kit
if errorlevel 1 (
    echo.
    echo   工具包文件有问题，先把整个目录重新解压一遍再试。
    goto :end
)
echo.

rem ---- device ip ----
echo   设备 IP 一般能在路由器/上级设备的管理页看到，
echo   也可以用 "arp -a" 在列表里找（不是本机、不是网关的那个 192.168.x.x）。
echo.
set TGT=
set /p TGT=  请输入设备 IP（直接回车 = 192.168.1.175）:
if "!TGT!"=="" set TGT=192.168.1.175
echo.
echo   目标设备: !TGT!
echo   下面进入主菜单。第一次操作会获取 root，之后所有操作都复用这条连接。
echo.

rem ============================================================
rem  交给 python 自己的菜单：一个进程、一条连接、一次 getroot
rem ============================================================
python wta301-getroot.py --target "!TGT!"

:end
echo.
echo ============================================================
echo   收尾提示
echo ============================================================
echo   正常退出时工具会自动删掉它加的网关别名和防火墙规则。
echo   如果中途强杀窗口导致没删干净，以管理员身份开 PowerShell 粘这五行：
echo.
echo     Remove-NetIPAddress -IPAddress 192.168.1.1  -PrefixLength 32 -Confirm:$false
echo     Remove-NetIPAddress -IPAddress 192.168.0.1 -PrefixLength 32 -Confirm:$false
echo     netsh advfirewall firewall delete rule name=WTA_ELINK
echo     netsh advfirewall firewall delete rule name=WTA_SRV
echo     netsh advfirewall firewall delete rule name=WTA_BKUP
echo.
echo   不删的话，本机访问 192.168.1.1 会指向自己。
echo.
pause
