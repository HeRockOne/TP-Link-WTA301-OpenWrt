#!/usr/bin/env bash
# make-getroot-kit.sh —— 生成「拿来就能用」的一键工具包（zip）
#
# 用户问题是：「把所有傻瓜式脚本需要的文件都放一起在一个目录，这样我就可以
# 直接打包走」。所以这里把散在四个地方的东西收进一个目录：
#
#   deliver/wta301-getroot.py        主程序
#   work/net/srv.py                  HTTP 服务（主程序的依赖）
#   work/net/elink_gw4.py            e-Link 模拟器（主程序的依赖）
#   deliver/stock/*.bin              四份原厂镜像
#   work/deliver-final-p29/*.bin     OpenWrt 包 + u-boot kit
#
# 缺任何一个文件就报错退出 —— 少一个依赖到现场才发现，比不打包更糟。
#
# 用法：
#   bash deliver/make-getroot-kit.sh                 # 输出到 ../wta301-kit
#   bash deliver/make-getroot-kit.sh /tmp/kit        # 指定输出目录
#
# 注意：必须在 WSL 里跑（要 powershell.exe 打 zip，中文文件名才不会乱）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="$(cd "$REPO/.." && pwd)"
OUT="${1:-$WORK/work/wta301-kit}"

say() { printf '%s\n' "$*"; }
die() { printf '[X] %s\n' "$*" >&2; exit 1; }

# ---- 定位各源文件 ----
SRV=""
for c in "$WORK/work/net/srv.py" "$WORK/net/srv.py" "$REPO/../net/srv.py"; do
    [ -f "$c" ] && { SRV="$c"; break; }
done
ELINK=""
for c in "$WORK/work/net/elink_gw4.py" "$WORK/net/elink_gw4.py" "$REPO/../net/elink_gw4.py"; do
    [ -f "$c" ] && { ELINK="$c"; break; }
done
P29=""
for c in "$WORK/work/deliver-final-p29" "$WORK/deliver-final-p29"; do
    [ -d "$c" ] && { P29="$c"; break; }
done

[ -n "$SRV" ]   || die "找不到 srv.py（主程序的依赖）"
[ -n "$ELINK" ] || die "找不到 elink_gw4.py（主程序的依赖）"
[ -f "$HERE/wta301-getroot.py" ] || die "找不到 deliver/wta301-getroot.py"
[ -d "$HERE/stock" ] || die "找不到 deliver/stock/"
[ -n "$P29" ] || die "找不到 deliver-final-p29/（OpenWrt 包和 u-boot kit）"

# ---- 校验镜像 md5（只认 md5，不认文件名）----
check_md5() {
    local want="$1" file="$2" name="$3"
    [ -f "$file" ] || die "缺 $name"
    local got
    got="$(md5sum "$file" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || die "$name md5 不符
    期望 $want
    实得 $got"
    say "   OK $name  $got"
}

# ---- 建目录 ----
say "输出目录: $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/stock" "$OUT/images"

# ---- 主程序与依赖 ----
cp "$HERE/wta301-getroot.py" "$OUT/"
cp "$SRV"   "$OUT/srv.py"
cp "$ELINK" "$OUT/elink_gw4.py"
say "主程序 3 个文件已就位"

# ---- 面向用户的入口：启动.bat + 使用说明.txt ----
# 这两个是 Windows 文件（CRLF，说明带 BOM），.gitattributes 已禁止行尾转换。
for f in "启动.bat" "使用说明.txt"; do
    [ -f "$HERE/kit/$f" ] || die "缺 deliver/kit/$f"
    cp "$HERE/kit/$f" "$OUT/"
done
say "启动器与说明已就位"

# ---- 原厂镜像 ----
say "原厂镜像:"
cp "$HERE/stock/mtd5_kernel.bin"        "$OUT/stock/"
cp "$HERE/stock/mtd6_rootfs.bin"        "$OUT/stock/"
cp "$HERE/stock/mtd10_kernel_bak.bin"   "$OUT/stock/"
cp "$HERE/stock/mtd11_rootfs_bak.bin"   "$OUT/stock/"
check_md5 170b2188884cc040d64ac5bed7ddc365 "$OUT/stock/mtd5_kernel.bin"      "A槽 2.0.2 kernel"
check_md5 30f487419d90b2239b65035390f3b73f "$OUT/stock/mtd6_rootfs.bin"      "A槽 2.0.2 rootfs"
check_md5 2868d8e975da7c641e54c72b6beb8f26 "$OUT/stock/mtd10_kernel_bak.bin" "B槽 4.4.60 kernel"
check_md5 bf2f92ceaf509093c8854825f2dc8d5e "$OUT/stock/mtd11_rootfs_bak.bin" "B槽 4.4.60 rootfs"

# ---- OpenWrt 包与 u-boot kit ----
say "OpenWrt 包:"
cp "$P29/wta301-op-25.12.6-p29.bin"            "$OUT/images/"
cp "$P29/wta301-op-25.12.6-p29-sysupgrade.bin" "$OUT/images/"
cp "$P29/wta301-uboot-p21c.bin"                "$OUT/images/"
[ -f "$P29/README-刷机说明.txt" ] && cp "$P29/README-刷机说明.txt" "$OUT/images/"
check_md5 c5ac0911accd2ec48033329c383d5c4c "$OUT/images/wta301-op-25.12.6-p29.bin"            "OpenWrt p29 完整包"
check_md5 76df463df4d8b5acba5d52852870c127 "$OUT/images/wta301-op-25.12.6-p29-sysupgrade.bin" "OpenWrt p29 sysupgrade"
check_md5 d0ada9f76e4f1aba9b96a559a5220cee "$OUT/images/wta301-uboot-p21c.bin"                "u-boot kit"

# ---- 清单 ----
{
    echo "# WTA301 一键工具 文件清单"
    echo "# 逐项核对: md5sum -c MD5SUMS.txt"
    echo "# Windows:  certutil -hashfile <文件> MD5"
    echo
    ( cd "$OUT" && md5sum 启动.bat 使用说明.txt wta301-getroot.py srv.py elink_gw4.py )
    ( cd "$OUT" && md5sum stock/*.bin )
    ( cd "$OUT" && md5sum images/* )
} > "$OUT/MD5SUMS.txt"
say "MD5SUMS.txt 已生成"

# ---- 打 zip（用 PowerShell，中文文件名才不会乱）----
ZIP="$OUT.zip"
rm -f "$ZIP"
PS=""
command -v powershell.exe >/dev/null 2>&1 && PS="powershell.exe"
if [ -z "$PS" ] && [ -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]; then
    PS="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
fi

if [ -n "$PS" ]; then
    WIN_OUT="$(wslpath -w "$OUT" 2>/dev/null || echo "$OUT")"
    WIN_ZIP="$(wslpath -w "$ZIP" 2>/dev/null || echo "$ZIP")"
    "$PS" -NoProfile -Command "Compress-Archive -Path '$WIN_OUT' -DestinationPath '$WIN_ZIP' -CompressionLevel Optimal -Force" >/dev/null
    say "已打 zip: $ZIP  ($(du -h "$ZIP" | cut -f1))"
elif command -v zip >/dev/null 2>&1; then
    ( cd "$(dirname "$OUT")" && zip -qr -UN=UTF8 "$ZIP" "$(basename "$OUT")" )
    say "已打 zip: $ZIP  ($(du -h "$ZIP" | cut -f1))"
else
    say "没找到 powershell.exe / zip，跳过打 zip（目录本身已完整可用）"
fi

say ""
say "完成。目录 $OUT"
say "  文件 $(find "$OUT" -type f | wc -l) 个，$(du -sh "$OUT" | cut -f1)"
say "  整个目录（或 .zip）一起拷走，不要只拷 .py 文件。"
