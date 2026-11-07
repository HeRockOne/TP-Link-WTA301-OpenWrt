#!/bin/bash
# 从 25.12.6 源码构建产物 → 可刷四件套（P3）
# 运行：bash deliver/make-release.sh [--version P29-2512] [--stage P29]
set -u
_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/lib-paths.sh"
die(){ echo "*** FAIL: $*"; exit 1; }

need_tree || exit 1
need_tool mk_op_pack.py || exit 1

# ★ 变量语义冲突提醒：lib-paths.sh 的 OUT 是「交付目录」（$REL/deliver），
#   而本脚本历史上用 OUT 指「出包根」，产物在 $OUT/pack。两者不能混。
#   这里显式改回出包根，否则 pack 会跑到 $REL/deliver/pack，
#   而 make-deliverable.sh 找的是 $REL/pack。
OUT=$REL
PACK=$OUT/pack

# ── 参数解析（以前这里没有，--version/--stage 被默默丢弃，-- ★ 真 bug）──
VERSION=""
STAGE=""
PURPOSE=""
while [ $# -gt 0 ]; do
	case "$1" in
	--version) VERSION=${2:-}; shift 2 || die "--version 缺值" ;;
	--stage)   STAGE=${2:-};   shift 2 || die "--stage 缺值" ;;
	--purpose) PURPOSE=${2:-}; shift 2 || die "--purpose 缺值" ;;
	-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
	*) die "未知参数：$1" ;;
	esac
done
# 未给就用当前仓库状态推一个，不静默编成旧版本号
[ -n "$VERSION" ] || VERSION="$(date +%Y%m%d)-local"
[ -n "$STAGE" ]   || STAGE="dev"
[ -n "$PURPOSE" ] || PURPOSE="25.12.6 / 6.12.112 本地构建（<$STAGE>）"
echo "== 版本=$VERSION  阶段=$STAGE =="

cd "$OWTREE" || die "进不去 $OWTREE"

echo "== 1. 找 sysupgrade 包 =="
SYSUP=$(ls -1t bin/targets/qualcommax/ipq50xx/*tplink_wta301*squashfs-sysupgrade.bin 2>/dev/null | head -1)
[ -n "$SYSUP" ] || die "没有 sysupgrade.bin（构建还没产出镜像？）"
echo "  $SYSUP  $(stat -c%s "$SYSUP") B"

echo "== 2. 拆包取 kernel(ITB) + root(squashfs) =="
rm -rf $OUT; mkdir -p $OUT/unpack
tar -xf "$SYSUP" -C $OUT/unpack || die "tar 解包失败"
K=$(find $OUT/unpack -name kernel -type f | head -1)
R=$(find $OUT/unpack -name root -type f | head -1)
[ -n "$K" ] && [ -n "$R" ] || die "包内没有 kernel/root"
echo "  kernel $K  $(stat -c%s "$K") B"
echo "  root   $R  $(stat -c%s "$R") B"

echo "== 3. 形状校验 =="
python3 - "$K" "$R" <<'PY' || exit 1
import sys,struct
k=open(sys.argv[1],'rb').read(); r=open(sys.argv[2],'rb').read()
ok=True
if k[:4]!=b'\xd0\x0d\xfe\xed': print("  *** kernel 不是 FIT"); ok=False
else:
    ts=struct.unpack('>I',k[4:8])[0]
    print("  FIT totalsize %d %s"%(ts,"OK" if ts==len(k) else "!= 文件长度 ***"))
    ok &= ts==len(k)
    if len(k)>0x740000: print("  *** kernel %d > 0x740000 (KERNEL_MAX)"%len(k)); ok=False
if r[:4]!=b'hsqs': print("  *** root 不是 squashfs"); ok=False
else: print("  squashfs 4.%d, %d B %s"%(r[28],len(r),"OK" if len(r)<=0xbc0000 else "> 0xbc0000 ***"))
if len(r)>0xbc0000: ok=False
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || die "形状校验不通过"

echo "== 4. 打包（mk_op_pack.py，带 u-boot 槽让 +0x90 自洽）=="
# --kblk 0x480000：内核区必须按 S7 的整区长度补齐，不能只对齐到 NAND 擦除块。
# 依据：S7 tphdr +0x5c KERNEL_LEN=0x480000，且 +0xa0 = md5(kernel[0:0x480000] ‖ rootfs[0:0xbc0000])；
# u-boot 按 KERNEL_LEN 从 NAND 读该长度算 md5，若只写 0x420000 则尾部残留旧数据 => 校验必失败。
#
# ★ u-boot 槽文件（262144 B）不在本仓库里（.gitignore 全 *.bin）。
#   它只影响 tphdr +0x90 那 16 字节 —— 该字段 = 『最终会存在于 0x4700000
#   的那 262144 字节』的 md5，一级 u-boot 拿它校验 A 槽 u-boot。
#   三种情况：
#     ① 你从 Releases 下了 wta301-uboot-p21c.bin → 放到下面任一位置，一次写对（推荐）
#     ② 你不打算刷 u-boot（板上就是原厂）→ 保持原厂值就对了
#     ③ 你要刷自己的 u-boot → 必须按「kernel/rootfs/tphdr 先、u-boot 最后」
#        的顺序刷（flash_uboot_direct.py 会回写 +0x90），否则掉 B 槽
UB_SLOT=${UBOOT_SLOT:-}
if [ -z "$UB_SLOT" ]; then
	for c in "$WORK/backup/mtd4_normal_boot.bin" \
	         "$SRC/patches/uboot/wta301-uboot-p21c.bin" \
	         "$SRC/patches/uboot/u-boot-slot.bin"; do
		[ -f "$c" ] && { UB_SLOT=$c; break; }
	done
fi
UB_ARGS=()
if [ -n "$UB_SLOT" ] && [ -f "$UB_SLOT" ]; then
	UB_ARGS=(--uboot "$UB_SLOT")
else
	cat >&2 <<'NOUB'
   ⚠️ 没找到 u-boot 槽文件（262144 B）—— tphdr 的 +0x90 将保持原厂值。
      这不影响本镜像的内核/rootfs；只影响「A 槽 u-boot 自身」的校验。
      · 板上 u-boot 仍是原厂 → 原厂值就是对的，无需处理
      · 要刷自编译 u-boot → 先刷 kernel/rootfs/tphdr，**最后**刷 u-boot
        （flash_uboot_direct.py 会回写 +0x90）
      · 想要一次写对 → 从 Releases 下 wta301-uboot-p21c.bin，放进
        patches/uboot/ 或用 UBOOT_SLOT=<路径> 指定
NOUB
fi
python3 "$TOOLS/mk_op_pack.py" --kernel "$K" --root "$R" --outdir $OUT/pack \
        --kblk 0x480000 "${UB_ARGS[@]}" || die "mk_op_pack 失败"

echo "== 5. UBI overlay：现造空卷，卷名必须是 wta301data =="
# 卷名由 bootargs 的 fstools_overlay_name=wta301data 决定（与 S7 逐字一致）。
# 25.12.6 的 fstools 确实支持该参数：mount_root.c:42
#     if (get_var_from_file("/proc/cmdline", "fstools_overlay_name", dataparam, ...))
#         dataname = dataparam;
#     data = volume_find(dataname);
# get_var_from_file 按 '=' 取 value ⇒ 卷名必须是 wta301data，不能是 rootfs_data。
# 若卷名写成 rootfs_data，volume_find("wta301data") 找不到 ⇒ 落到 rootdisk driver
# （把 squashfs 尾部剩余空间当 overlay，本板 = mtd7 仅 3.6MB）⇒ 首启无 overlay。
# 几何必须与 S7 冻结镜像一致：2048/LEB 126976(0x1f000)/PEB 131072/subpage 2048/autoresize。
# HOSTBIN 由 lib-paths.sh 解析（优先 $OWTREE/staging_dir/host/bin，
# 回落到本机历史使用的 nss-edma 那套）；这里不再写死。
UBIVOL=wta301data
UBIIMG=ubi_rootfs_data3_$UBIVOL.img
if [ -x "$HOSTBIN/mkfs.ubifs" ] && [ -x "$HOSTBIN/ubinize" ]; then
    rm -rf $OUT/ubitmp && mkdir -p $OUT/ubitmp/empty
    $HOSTBIN/mkfs.ubifs -m 2048 -e 126976 -c 289 -F -x zlib -r $OUT/ubitmp/empty \
        -o $OUT/ubitmp/ubifs.img > /dev/null 2>&1 || die "mkfs.ubifs 失败"
    printf '[%s]\nmode=ubi\nimage=%s\nvol_id=0\nvol_type=dynamic\nvol_name=%s\nvol_flags=autoresize\n' \
        $UBIVOL $OUT/ubitmp/ubifs.img $UBIVOL > $OUT/ubitmp/ubinize.cfg
    $HOSTBIN/ubinize -o $OUT/pack/$UBIIMG \
        -m 2048 -p 131072 -s 2048 -O 2048 $OUT/ubitmp/ubinize.cfg > /dev/null 2>&1 \
        || die "ubinize 失败"
    rm -rf $OUT/ubitmp
    echo "  已生成 $UBIIMG  $(stat -c%s $OUT/pack/$UBIIMG) B"
else
    die "找不到 mkfs.ubifs/ubinize（$HOSTBIN）"
fi

# 把 UBI 区补进刷写序列：mk_op_pack 只产 kernel/rootfs/tphdr 三区，
# 但 overlay 区必须一起刷（否则仍是 S7 的 /etc/config，会污染首启网络与无线配置）。
# 顺序：kernel -> rootfs -> ubi -> tphdr（tphdr 最后，头一改校验就变）。
UBILEN=$(stat -c%s $OUT/pack/$UBIIMG)
UBILENHEX=$(printf '0x%x' $UBILEN)
python3 - "$OUT/pack/flash_cmds.txt" "$UBILENHEX" "$UBIIMG" <<'PYEOF'
import sys
path, ublen, ubimg = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding='utf-8').read().splitlines()
ubi = ['printenv ;tftpboot 0x44000000 ' + ubimg,
       'printenv ;nand erase 0x1bc0000 0x2440000',
       'printenv ;nand write 0x44000000 0x1bc0000 ' + ublen]
# 插在 tphdr 三条之前
cut = next(i for i, l in enumerate(lines) if 'op_tphdr_0x20000.bin' in l)
lines = lines[:cut] + ubi + lines[cut:]

# AGENTS 5.5：每区写完后立刻 nand read 到旁址 + crc32，与本地文件 crc32（FINGERPRINT.json）逐区对比。
# 旁址用 0x43000000（4MiB 处 → 0x44000000，不与任何在飞缓冲重叠）。
out, i = [], 0
while i < len(lines):
    out.append(lines[i])
    if 'nand write' in lines[i]:
        tok = lines[i].split()      # ['printenv', ';nand', 'write', ram, addr, len]
        _ram, addr, ln = tok[-3], tok[-2], tok[-1]
        out.append('printenv ;nand read 0x43000000 %s %s' % (addr, ln))
        out.append('printenv ;crc32 0x43000000 %s' % ln)
    i += 1
lines = out
open(path, 'w', newline='\n').write('\n'.join(lines) + '\n')
print('  已插入 UBI 区 3 条命令 (len=%s) + 每区 crc32 校验 2 条' % ublen)
PYEOF
ls -la $OUT/pack/

echo "== 6. FINGERPRINT.json + tphdr 自洽复核 =="
python3 --version >/dev/null
# ★ 之前这里的 --version/--stage 是**写死的 P28**，而本脚本又不解析命令行参数，
#   于是传进来的 --version P29-2512 被默默丢弃，p29 包的 FINGERPRINT.json
#   里写的是 P28-2512。现已改为真解析（见脚本开头的 getopt）。
python3 "$TOOLS/mk_fingerprint.py" $OUT/pack \
	--version "$VERSION" --stage "$STAGE" \
	--purpose "$PURPOSE" \
	--bootargs "root=/dev/mtdblock6 rootfstype=squashfs rootwait coherent_pool=2M ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data" \
	--rollback-to S7 --rollback-kernel 53bd0490 --rollback-rootfs c2e227c6 --rollback-tphdr 3ccbcfc4 \
	|| die "mk_fingerprint 失败"

echo "== 7. sysupgrade 包（系统内升级用，不必进 u-boot）=="
# 这是 OpenWrt 原生 tar：sysupgrade-<board>/{CONTROL,kernel,root} + fwtool 元数据尾。
# 从 P28 起 ipq50xx/platform.sh 有了 tplink,wta301 分支，可以直接刷这个包：
#   LuCI -> 系统 -> 备份/刷写固件  或  sysupgrade -v <包>
# 只写 mtd5(kernel) + mtd6(rootfs)，不碰 mtd12 上的 overlay 卷 wta301data
# => 全部 UCI 配置和已装包自动保留。
# 救砖 / 换 u-boot 仍然必须用上面的 u-boot 网页包（那个能写 normal_boot 和重做 UBI）。
cp -f "$SYSUP" $OUT/pack/ || die "复制 sysupgrade 包失败"
SYSUPNAME=$(basename "$SYSUP")
( cd $OUT/pack && md5sum "$SYSUPNAME" > "$SYSUPNAME.md5" )
echo "  $SYSUPNAME  $(stat -c%s "$OUT/pack/$SYSUPNAME") B"
echo "  md5 $(cut -d' ' -f1 "$OUT/pack/$SYSUPNAME.md5")"

echo
echo "== 完成：$OUT/pack =="
