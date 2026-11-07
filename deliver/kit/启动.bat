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
echo   目标设备: !TGT!
echo.

:menu
echo ============================================================
echo   1   只取 root（进 telnet 2323 看 uid）
echo   ----------------------------------------------
echo   2   安全审计（只读，看现在有几条退路）
echo   3   整片备份到本机 backup\  （约 126 MB）
echo   ----------------------------------------------
echo   4   刷 OpenWrt 到 A 槽   [先空跑再看]
echo   5   只刷 u-boot kit      [先空跑再看]
echo   ----------------------------------------------
echo   6   刷回原厂到 A 槽      [先空跑再看]
echo   7   修 B 槽（写回原厂）
echo   ----------------------------------------------
echo   8   看分区说明
echo   0   退出
echo ============================================================
set CHOICE=
set /p CHOICE=  请选择 [0-8]:

if "!CHOICE!"=="1" goto :do_root
if "!CHOICE!"=="2" goto :do_verify
if "!CHOICE!"=="3" goto :do_backup
if "!CHOICE!"=="4" goto :do_op
if "!CHOICE!"=="5" goto :do_uboot
if "!CHOICE!"=="6" goto :do_stock
if "!CHOICE!"=="7" goto :do_bslot
if "!CHOICE!"=="8" goto :do_explain
if "!CHOICE!"=="0" goto :end
echo   输入无效。
goto :menu

:do_root
python wta301-getroot.py --target !TGT!
goto :after

:do_verify
python wta301-getroot.py --target !TGT! --verify --keep
goto :after

:do_backup
echo.
echo   备份到 %CD%\backup  ——  需要 126 MB 空闲空间，约 3~6 分钟
set OK=
set /p OK=  继续? [y/N]:
if /i not "!OK!"=="y" goto :menu
python wta301-getroot.py --target !TGT! --backup backup --keep
goto :after

:do_op
echo.
echo   ===== 第 1 步：空跑，只看计划，不写任何东西 =====
python wta301-getroot.py --target !TGT! --flash-op "images\wta301-op-25.12.6-p29.bin" --dry-run --keep
echo.
set OK=
set /p OK=  计划没问题，真正写入? [y/N]:
if /i not "!OK!"=="y" goto :menu
echo.
echo   ===== 第 2 步：真正写入 =====
python wta301-getroot.py --target !TGT! --flash-op "images\wta301-op-25.12.6-p29.bin" --keep
goto :after

:do_uboot
echo.
echo   ===== 第 1 步：空跑 =====
python wta301-getroot.py --target !TGT! --flash-uboot "images\wta301-uboot-p21c.bin" --dry-run --keep
echo.
set OK=
set /p OK=  真正写入? [y/N]:
if /i not "!OK!"=="y" goto :menu
python wta301-getroot.py --target !TGT! --flash-uboot "images\wta301-uboot-p21c.bin" --keep
goto :after

:do_stock
echo.
echo   ===== 第 1 步：空跑 =====
python wta301-getroot.py --target !TGT! --flash-stock auto --dry-run --keep
echo.
echo   A 槽会被写成原厂 2.0.2，B 槽不动。
echo   两个目标都不是活动分区，写完会做完整回读校验，不重启。
set OK=
set /p OK=  真正写入? [y/N]:
if /i not "!OK!"=="y" goto :menu
python wta301-getroot.py --target !TGT! --flash-stock auto --keep
goto :after

:do_bslot
echo.
echo   ===== 第 1 步：空跑 =====
python wta301-getroot.py --target !TGT! --restore-bslot --dry-run --keep
echo.
set OK=
set /p OK=  真正写入 B 槽? [y/N]:
if /i not "!OK!"=="y" goto :menu
python wta301-getroot.py --target !TGT! --restore-bslot --keep
goto :after

:do_explain
python wta301-getroot.py --explain
goto :after

:after
echo.
echo ============================================================
set AGAIN=
set /p AGAIN=  回菜单? [Y/n]:
if /i "!AGAIN!"=="n" goto :end
goto :menu

:end
echo.
echo ============================================================
echo   收尾提示
echo ============================================================
echo   本工具会给本机加两个假网关地址，用完建议删掉。
echo   以管理员身份开 PowerShell，粘这五行：
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
