#!/bin/bash
# apply-rootfs-only.sh —— 只铺「用户态」的那部分（§5e + §5f）
#
# 为什么需要这个脚本
# ------------------
# `apply-to-2512.sh` 会碰 target/linux/qualcommax/patches-6.12 与 files/。
# 只要这两个目录的 mtime 变了，OpenWrt 就会**重新解包内核树 + 全量重编内核**
# （本机实测：一次 45 分钟以上，之后还要重编依赖 vermagic 的包）。
#
# 而我们日常迭代最多的是：
#   - files-rootfs/       （rootfs overlay：脚本、sysctl、init.d）
#   - files-base-files/   （config/wireless、uci-defaults）
# 这两块**完全不碰内核**，只影响 base-files 包和 rootfs 镜像组装。
#
# 所以：改这两块时用本脚本，几分钟出镜像；改内核/驱动/DTS/补丁时才用
# apply-to-2512.sh 全量。
#
# ⚠ 前置条件：全量脚本**至少跑过一次**（内核补丁、DTS、Device 块都在位）。
#   本脚本不做任何内核侧校验，缺失时会在编译阶段以别的形式报错。
#
# 用法（WSL，root）：
#     wsl -d Ubuntu2404 -u root bash /mnt/c/.../wta301-2512/deliver/apply-rootfs-only.sh
# 之后：
#     make -j6 target/install
#
set -e
SRC=/mnt/c/Users/Sophia/Downloads/Compressed/wta301e3tyv1_cn_1_0_10_up_boot/wta301-2512
T=/root/ow2512/target/linux/qualcommax
[ -d /root/ow2512 ] || { echo "*** 没有 /root/ow2512"; exit 1; }
[ -d "$T/ipq50xx/base-files" ] || { echo "*** 编译树没准备好（先跑 apply-to-2512.sh）"; exit 1; }

echo "== 5e. rootfs overlay（net-tune 守护 + sysctl + rc.d）=="
ROOTFILES=/root/ow2512/files
# 旧的 rps-watch 三件套已被上游 packet_steering 取代，残留会把 rps_cpus 拉回
# 单核（上游脚本会跟它打架）。先清掉已装到编译树的旧拷贝。
rm -f $ROOTFILES/usr/sbin/rps-watch $ROOTFILES/etc/init.d/rps \
      $ROOTFILES/etc/sysctl.d/99-wta301-rps.conf $ROOTFILES/etc/rc.d/S99rps
mkdir -p $ROOTFILES
cp -a $SRC/files-rootfs/. $ROOTFILES/
chmod 0755 $ROOTFILES/usr/sbin/net-tune $ROOTFILES/etc/init.d/net-tune
# /etc/rc.d 符号链接：OpenWrt 用 S<NN><name> -> ../init.d/<name> 控制开机顺序。
# 不用 `/etc/init.d/net-tune enable` 的原因是那要等板子起来跑；构建期放链接才叫固化。
mkdir -p $ROOTFILES/etc/rc.d
ln -sf ../init.d/net-tune $ROOTFILES/etc/rc.d/S99net-tune
find $ROOTFILES -type f -o -type l | sed "s|$ROOTFILES|  files/|"

echo "== 5f. base-files（无线出厂值 + packet steering 兜底）=="
BB=$T/ipq50xx/base-files
cp -f $SRC/files-base-files/etc/config/wireless                 $BB/etc/config/wireless
cp -f $SRC/files-base-files/etc/uci-defaults/99-wta301-wireless $BB/etc/uci-defaults/99-wta301-wireless
cp -f $SRC/files-base-files/etc/uci-defaults/99-wta301-net      $BB/etc/uci-defaults/99-wta301-net
chmod 0644 $BB/etc/config/wireless
chmod 0755 $BB/etc/uci-defaults/99-wta301-wireless $BB/etc/uci-defaults/99-wta301-net
echo "  wireless:"
grep -E "^\s*option (band|channel|htmode|country|cell_density|noscan)" $BB/etc/config/wireless | sed 's/^/    /'
echo "  packet steering:"
grep -E "packet_steering|steering_flows" $BB/etc/uci-defaults/99-wta301-net | sed 's/^/    /'
echo ""
echo "★ 注意：本脚本刻意不碰 target/linux/.../{patches-6.12,files}，"
echo "  所以**不会**触发内核重编。接下来只需：make -j6 target/install"
