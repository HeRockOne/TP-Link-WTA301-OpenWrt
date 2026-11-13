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
# 用法：
#     bash deliver/apply-rootfs-only.sh
#     OWTREE=/path/to/openwrt bash deliver/apply-rootfs-only.sh
# 之后：
#     make -j6 package/install && make -j6 target/install
#
# ⚠ 必须是上面两条，不能只跑 target/install。
#   实测（2026-11-11）：只改 files/ 里的**已存在文件**的内容时，
#   `make target/install` 出来的镜像里还是旧内容，且不报任何错。
#   原因：把 $(TOPDIR)/files 铺进 $(TARGET_DIR) 的那一步在
#   `package/Makefile:126`（`$(call prepare_rootfs,$(TARGET_DIR),$(TOPDIR)/files)`），
#   它属于 `make package/install` 而不是 `make target/install`。
#   `target/install` 只是把已有的 root-qualcommax 打成 squashfs。
#   以前这里只写了 target/install，照着做会得到“文件改了但镜像没变”
#   的假成功 —— 排查了很久，记在这里。
#
set -e
_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/lib-paths.sh"

T=$OWTREE/target/linux/qualcommax
[ -f "$OWTREE/Makefile" ] || { echo "*** 没有 OpenWrt 树：$OWTREE"; exit 1; }
[ -d "$T/ipq50xx/base-files" ] || { echo "*** 编译树没准备好（先跑 apply-to-2512.sh）"; exit 1; }

echo "== 5e. rootfs overlay（net-tune 守护 + sysctl + rc.d）=="
ROOTFILES=$OWTREE/files
# 旧的 rps-watch 三件套已被上游 packet_steering 取代，残留会把 rps_cpus 拉回
# 单核（上游脚本会跟它打架）。先清掉已装到编译树的旧拷贝。
rm -f $ROOTFILES/usr/sbin/rps-watch $ROOTFILES/etc/init.d/rps \
      $ROOTFILES/etc/sysctl.d/99-wta301-rps.conf $ROOTFILES/etc/rc.d/S99rps
mkdir -p $ROOTFILES

# ---------------------------------------------------------------------------
# 剪掉「上次装过、这次仓库里已经没有」的文件
#
# 踩过的坑：`cp -a` 只会覆盖和新增，不会删除。p33 试做时往 files-rootfs 里
# 放过 usr/sbin/wta301-slot 和 luci 的 menu.d/acl.d/view 四个文件，后来决定
# 退回 p31 基线、把这四个从仓库移走，但编译树里的是旧拷贝 —— 不加这一步，
# “p31 基线”的镜像里会静默带着 p33 的双系统切换菜单，差异表会对不上。
#
# 只删**普通文件**（-type f）：本脚本自己在下面创建的 /etc/rc.d 符号链接不能碰。
# $OWTREE/files（rootfs overlay）在本项目里只由本脚本与 apply-to-2512.sh §5e
# 写入，$T/files 那个内核 overlay 是另一个目录，与此处无关。
# ---------------------------------------------------------------------------
if [ -d "$ROOTFILES" ]; then
	while IFS= read -r _f; do
		_rel=${_f#$ROOTFILES/}
		if [ ! -e "$SRC/files-rootfs/$_rel" ]; then
			rm -f "$_f"
			echo "  prune files/$_rel"
		fi
	done < <(find "$ROOTFILES" -type f)
	find "$ROOTFILES" -mindepth 1 -type d -empty -delete 2>/dev/null || true
fi

cp -a $SRC/files-rootfs/. $ROOTFILES/
# ---------------------------------------------------------------------------
# 权限归一化（必须，别删）
#
# 构建跑在 WSL 里，而源码在 /mnt/c（DrvFs）。WSL 默认不启用 metadata，
# 所以 /mnt/c 下所有文件在 Linux 眼里都是 777 —— 那是假权限，不是仓库里的真实
# 权限（Windows 侧看是 644/755）。上面那条 `cp -a` 会把这个假 777 原样带进
# 构建树的 files/，再打进 squashfs。
#
# 踩过的坑：/usr/share/rpcd/ucode/wta301 变成 777 后，rpcd 的 ucode 插件会
# 静默跳过它（上游 rpcd/ucode.c：`if (s.st_mode & S_IWOTH) { "Ignoring ucode
# script ..." ; continue; }`），ubus 里根本没有 wta301 对象，于是 LuCI 概览页
# 的「CPU 使用率与温度」整段消失，前端只报 Not found，看不出是权限问题。
#
# 所以这里不依赖源文件的权限，按 rootfs 惯例重新定：
#   目录 755 / 普通文件 644 / init.d 与 sbin 下的脚本 755
# ---------------------------------------------------------------------------
find $ROOTFILES -type d -exec chmod 0755 {} +
find $ROOTFILES -type f -exec chmod 0644 {} +
find $ROOTFILES/etc/init.d $ROOTFILES/usr/sbin -type f -exec chmod 0755 {} + 2>/dev/null || true
chmod 0755 $ROOTFILES/usr/sbin/net-tune $ROOTFILES/etc/init.d/net-tune
chmod 0755 $ROOTFILES/usr/sbin/wta301-wifi-guard $ROOTFILES/etc/init.d/wta301-guard 2>/dev/null || true
# /etc/rc.d 符号链接：OpenWrt 用 S<NN><name> -> ../init.d/<name> 控制开机顺序。
# 不用 `/etc/init.d/net-tune enable` 的原因是那要等板子起来跑；构建期放链接才叫固化。
mkdir -p $ROOTFILES/etc/rc.d
ln -sf ../init.d/net-tune $ROOTFILES/etc/rc.d/S99net-tune
# wta301-guard：START=95，必须在 netifd/wifi 之后起来才能数到 AP。
# 板上是 `wta301-guard enable` 生成的，构建期直接放链接才是固化的。
ln -sf ../init.d/wta301-guard $ROOTFILES/etc/rc.d/S95wta301-guard
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
