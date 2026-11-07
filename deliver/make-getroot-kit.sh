#!/usr/bin/env bash
# make-getroot-kit.sh —— 生成「拿来就能用」的一键工具包（zip）
#
# 工具包是给【别人的 Windows 电脑】用的，所以：
#   · 只有 .bat / .ps1，不含任何 Python 脚本（对方电脑没有 python）
#   · 一台电脑完成全部操作（网线 getroot + 串口 TTL 都在同一个 ps1 里）
#   · u-boot 单独放 uboot/ 目录，不和固件包混在一起
#
# 目录布局：
#   wta301-kit/
#     启动.bat                 入口（提权 + 自检 + 问 IP）
#     wta301.ps1               全部逻辑（零依赖，Win10 自带 PowerShell 5.1）
#     使用说明.txt
#     MD5SUMS.txt
#     uboot/                   u-boot kit（刷 u-boot 用）
#     images/                  OpenWrt 包
#     stock/                   原厂回退镜像
#
# 用法：
#   bash deliver/make-getroot-kit.sh                 # 输出到 ../work/wta301-kit
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

P29=""
for c in "$WORK/work/deliver-final-p29" "$WORK/deliver-final-p29"; do
    [ -d "$c" ] && { P29="$c"; break; }
done

[ -f "$HERE/kit/wta301.ps1" ] || die "找不到 deliver/kit/wta301.ps1"
[ -d "$HERE/stock" ] || die "找不到 deliver/stock/"
[ -n "$P29" ] || die "找不到 deliver-final-p29/（OpenWrt 包和 u-boot kit）"

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

say "输出目录: $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/uboot" "$OUT/images" "$OUT/stock"

# ---- 程序（只有 ps1 + bat，无 python）----
cp "$HERE/kit/wta301.ps1" "$OUT/"
for f in "启动.bat" "使用说明.txt"; do
    [ -f "$HERE/kit/$f" ] || die "缺 deliver/kit/$f"
    cp "$HERE/kit/$f" "$OUT/"
done
say "程序已就位（PowerShell，零依赖）"

# ---- 原厂镜像 ----
say "原厂镜像:"
cp "$HERE/stock/mtd5_kernel.bin"        "$OUT/stock/"
cp "$HERE/stock/mtd6_rootfs.bin"        "$OUT/stock/"
cp "$HERE/stock/mtd10_kernel_bak.bin"   "$OUT/stock/"
cp "$HERE/stock/mtd11_rootfs_bak.bin"   "$OUT/stock/"
check_md5 170b2188884cc040d64ac5bed7ddc365 "$OUT/stock/mtd5_kernel.bin"      "A槽 2.0.2 kernel (0x4880000)"
check_md5 30f487419d90b2239b65035390f3b73f "$OUT/stock/mtd6_rootfs.bin"      "A槽 2.0.2 rootfs (0x4fc0000)"
check_md5 2868d8e975da7c641e54c72b6beb8f26 "$OUT/stock/mtd10_kernel_bak.bin" "B槽 4.4.60 kernel (0x880000)"
check_md5 bf2f92ceaf509093c8854825f2dc8d5e "$OUT/stock/mtd11_rootfs_bak.bin" "B槽 4.4.60 rootfs (0xfc0000)"

# ---- u-boot 单独一个目录 ----
say "u-boot kit:"
cp "$P29/wta301-uboot-p21c.bin" "$OUT/uboot/"
check_md5 d0ada9f76e4f1aba9b96a559a5220cee "$OUT/uboot/wta301-uboot-p21c.bin" "u-boot kit"
cat > "$OUT/uboot/README.txt" <<'EOF'
u-boot kit —— 这是二级 u-boot（A/B 两个槽都刷它，一级 u-boot 永不动）
  文件名  wta301-uboot-p21c.bin   262144 字节 (0x40000)
  md5     d0ada9f76e4f1aba9b96a559a5220cee
  落点    0x700000 (B 槽)  与  0x4700000 (A 槽)

为什么放在单独目录：
  这个文件和 OpenWrt 固件包是两回事。刷固件不动它，刷它不动固件。
  混在一起最容易出的事就是「想把固件刷回去，结果顺手把 u-boot 也换了」。

什么时候需要刷它：
  只有需要 kit 的 tplcheck / tplflash / 跳过槽头 md5 校验时才刷。
  平时刷 OpenWrt、刷回原厂都不需要动 u-boot。

危险提示：
  一级 u-boot 在 mtd0 (0x0..0x3c0000)，本工具从未写过它，也永远不会写。
  它有一整套救砖能力（tftp / nand / bootm / crc32 / Web 恢复 192.168.1.1）
  和双向回退（一个槽验不过自动去验另一个）。
EOF
say "   OK uboot/README.txt"

# ---- OpenWrt 包 ----
say "OpenWrt 包:"
cp "$P29/wta301-op-25.12.6-p29.bin"            "$OUT/images/"
cp "$P29/wta301-op-25.12.6-p29-sysupgrade.bin" "$OUT/images/"
check_md5 c5ac0911accd2ec48033329c383d5c4c "$OUT/images/wta301-op-25.12.6-p29.bin"            "OpenWrt p29 完整包"
check_md5 76df463df4d8b5acba5d52852870c127 "$OUT/images/wta301-op-25.12.6-p29-sysupgrade.bin" "OpenWrt p29 sysupgrade"

# ---- 清单 ----
{
    echo "# WTA301 一键工具 文件清单"
    echo "# 程序是纯 PowerShell，不需要装 Python"
    echo "# WSL/Linux:  md5sum -c MD5SUMS.txt"
    echo "# Windows :  certutil -hashfile <文件> MD5"
    echo
    ( cd "$OUT" && md5sum 启动.bat 使用说明.txt wta301.ps1 )
    ( cd "$OUT" && md5sum uboot/* )
    ( cd "$OUT" && md5sum stock/*.bin )
    ( cd "$OUT" && md5sum images/* )
} > "$OUT/MD5SUMS.txt"
say "MD5SUMS.txt 已生成"

# ---- 打 zip ----
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
say "  整个目录（或 .zip）一起拷走。对方电脑只要有 Windows 自带的 PowerShell 就行。"
