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
python3 $W/work/op-build/mk_op_pack.py --kernel "$K" --root "$R" --outdir $OUT/pack \
        --uboot $W/work/backup/mtd4_normal_boot.bin || die "mk_op_pack 失败"

echo "== 5. UBI overlay：直接复用冻结的 S7 镜像 =="
cp $W/work/backup/FROZEN-S7-20261105/ubi_rootfs_data3_wta301data.img $OUT/pack/ || die "复制 UBI 失败"
ls -la $OUT/pack/

echo "== 6. 独立复核 tphdr（不依赖打包器的自述）=="
python3 - $OUT/pack <<'PYEOF' || exit 1
import sys,os,struct,hashlib
d=sys.argv[1]
h=open(os.path.join(d,'op_tphdr_0x20000.bin'),'rb').read()
k=open(os.path.join(d,'op_kernel_0x480000.bin'),'rb').read()
r=open(os.path.join(d,'op_rootfs_0xbc0000.bin'),'rb').read()
be=lambda o: struct.unpack('>I',h[o:o+4])[0]
exp={0x48:0x4700000,0x4c:0x40000,0x50:0x4800000,0x54:0x20000,0x58:0x4880000}
ok=True
for o,v in exp.items():
    got=be(o); print("  0x%02x = 0x%x %s"%(o,got,"OK" if got==v else "!= 0x%x ***"%v)); ok&=got==v
kl,rl=be(0x5c),be(0x64)
print("  0x5c(klen)=0x%x  0x60(rootoff)=0x%x  0x64(rverify)=0x%x"%(kl,be(0x60),rl))
print("  kernel 文件 %d B  root 文件 %d B"%(len(k),len(r)))
print("  +0xa0 = md5(kernel||root) %s"%("OK" if h[0xa0:0xb0]==hashlib.md5(k[:kl]+r[:rl]).digest() else "*** 不匹配"))
ok &= h[0xa0:0xb0]==hashlib.md5(k[:kl]+r[:rl]).digest()
ub=os.path.join('$W','work/backup/mtd4_normal_boot.bin')
ub=open(ub,'rb').read()
print("  +0x90 = md5(normal_boot) %s"%("OK" if h[0x90:0xa0]==hashlib.md5(ub).digest() else "*** 不匹配"))
ok &= h[0x90:0xa0]==hashlib.md5(ub).digest()
sys.exit(0 if ok else 1)
PYEOF
[ $? -eq 0 ] || die "tphdr 复核不通过"
echo
echo "== 完成：$OUT/pack =="
