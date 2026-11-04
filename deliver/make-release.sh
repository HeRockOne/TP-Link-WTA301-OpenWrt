#!/bin/bash
# 从 25.12.6 源码构建产物 → 可刷四件套（P3）
# 运行（WSL，root）：wsl -d Ubuntu2404 -u root bash /root/make-release.sh
set -u
W=/mnt/c/Users/Sophia/Downloads/Compressed/wta301e3tyv1_cn_1_0_10_up_boot
OUT=/root/rel
die(){ echo "*** FAIL: $*"; exit 1; }

cd /root/ow2512 || die "no ow2512"

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
python3 $W/work/op-build/mk_op_pack.py --kernel "$K" --root "$R" --outdir $OUT/pack \
        --kblk 0x480000 \
        --uboot $W/work/backup/mtd4_normal_boot.bin || die "mk_op_pack 失败"

echo "== 5. UBI overlay：直接复用冻结的 S7 镜像 =="
cp $W/work/backup/FROZEN-S7-20261105/ubi_rootfs_data3_wta301data.img $OUT/pack/ || die "复制 UBI 失败"
ls -la $OUT/pack/

echo "== 6. FINGERPRINT.json + tphdr 自洽复核 =="
python3 --version >/dev/null
python3 "$W/wta301-2512/tools/mk_fingerprint.py" $OUT/pack         --version P3-2512 --stage P3         --purpose "25.12.6 / kernel 6.12.112 首次真机验证"         --bootargs "root=/dev/mtdblock6 rootfstype=squashfs rootwait coherent_pool=2M ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data"         --rollback-to S7 --rollback-kernel 53bd0490 --rollback-rootfs c2e227c6 --rollback-tphdr 3ccbcfc4   || die "mk_fingerprint 失败"

echo
echo "== 完成：$OUT/pack =="