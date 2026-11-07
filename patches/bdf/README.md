# patches/bdf/ —— 用你自己的 ART 生成 board-2.bin

**这个目录里的 `.bin` 不随仓库分发。** 你看到这个文件说明你 clone 下来后
还没有生成它们 —— 这是预期状态，不是缺文件。

---

## 为什么不分发

`board-2.bin` 是 ath11k 的「板型容器」，里面装一块 131,072 字节的 BDF。
本板的 ART 分区（`mtd2`）在 `+0x1000` 与 `+0x26800` 各存一份 128 KiB 数据 ——
那是**每台机器出厂时逐台校准的**射频参数（功率、频偏等）。

按 GPL 可以分发我们自己写的代码，但**厂商烧进 flash 的校准数据不该由我们转手**。
所以仓库只留生成脚本。

### 技术上的补充（免得你以为不分发会掉性能）

运行时 ath11k 的校准**始终来自刷机者自己的 ART** —— 固件里有
`etc/hotplug.d/firmware/12-wta301-caldata`，开机时从本机 ART 提取
`cal-ahb-*.wifi.bin`：

```
IPQ5018 : virtual_art.bin + 0x1000   len 0x20000
qcn6122 : virtual_art.bin + 0x26800  len 0x20000
```

所以别人刷了这个固件，用的**不是**作者的校准。`board-2.bin` 只负责
板型 / variant 匹配（必须有，否则 ath11k 报 `-12` 加载失败）。

这一点已实证，推导过程见 `docs/M12-FIRMWARE-BDF.md` §1.2。

---

## 怎么生成

先拿到本机 root（不拆机、不接 TTL）：见 `tools/getroot/README.md`。

### 路子 1：在板子上直接跑（推荐，读的就是本机真实校准）

```bash
scp tools/mk_board2_from_art.py root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "python3 /tmp/mk_board2_from_art.py --art /dev/mtdblock2 --outdir /tmp/bdf"
scp root@192.168.1.1:/tmp/bdf/board2-wta301-*.bin patches/bdf/
```

### 路子 2：板子没有 python3 时，先 dump 到本地再跑

```bash
ssh root@192.168.1.1 "dd if=/dev/mtdblock2 of=/tmp/art.bin"
scp root@192.168.1.1:/tmp/art.bin .
python3 tools/mk_board2_from_art.py --art art.bin --outdir patches/bdf
```

### 路子 3：显式指定目录

```bash
BDFDIR=/path/to/bdf bash deliver/apply-to-2512.sh
```

---

## 生成后会得到什么

```
patches/bdf/board2-wta301-ipq5018-2g.bin    131,072 B+  （2.4G，IPQ5018）
patches/bdf/board2-wta301-qcn6122-5g.bin    131,072 B+  （5G，QCN6122）
```

校验（`deliver/verify-repro.sh` §8 会自动做同样的事）：

```bash
python3 tools/parse_board2.py patches/bdf/board2-wta301-ipq5018-2g.bin
# 要能看到 variant=TP-Link-WTA301，且 BDF 大小 131072
```

variant 名必须与 DTS 的 `qcom,ath11k-calibration-variant` 逐字节一致 ——
对不上 ath11k 会 `-12` 加载失败，Wi-Fi 起不来。

---

## 原厂 rootfs 里的 `bdwlan.b10` / `bdwlan.b50` 能用吗

能起，但会丢掉逐台校准。实测两者差异极小（2.4G 差 25 字节、5G 差 79 字节，
集中在 `0xa` 头字段和 `0x1a00+` / `0x2700+` 的功率校准区）：

```
bdwlan   = 通用模板
ART 里的 = 通用模板 + 逐台校准微调
```

所以优先用自己 ART 里的。

---

## 相关

- `THIRD-PARTY.md` §2 —— 这个决定的完整说明与影响评估
- `tools/mk_board2_from_art.py` —— 生成器（306 行，只用标准库）
- `tools/parse_board2.py` —— 容器解析/校验
- `docs/M12-FIRMWARE-BDF.md` —— 推导过程
- `.gitignore` —— `patches/bdf/*.bin` 已被忽略，误 `git add` 不会入库

