# P5 包集对齐（LuCI + zram）

**目的**：把 P3 那版"故意不带 Web UI"的镜像补齐到与 S7 可用性等价的包集，
仍然遵守 **单一变量**：只加包，不碰内核配置、不碰 DTS、不碰以太网栈。

## 1. 差异清单（S7 178 包 vs P3 147 包）

真实差异只有两组（其余 100+ 条是 lib ABI 改名，同一个库换了 soname 版本）：

| 组 | 包 | 来源 |
|---|---|---|
| Web UI | `luci` `luci-ssl` `luci-theme-bootstrap` `luci-app-firewall` `luci-app-package-manager` `cgi-io` | feeds/luci + feeds/packages |
| 内存 | `zram-swap`（自动拉 `kmod-zram`） | core（`package/system/zram-swap`） |

清单固化在 `deliver/s7-parity-packages.txt`，S7 侧完整包表在 `pin/s7-packages.txt`。

## 2. 构建动作

```sh
cp .config /root/config-p3.bak           # 留退路（P3 那份可随时回去）
printf 'CONFIG_PACKAGE_luci=y\n...' >> .config
make defconfig
FORCE_UNSAFE_CONFIGURE=1 make -j8        # 只此一条，别并发第二个 make
```

feeds 必须先装全：`scripts/feeds update -a && scripts/feeds install -a`
（P3 时只装了 `base`，所以 147 包里没有 LuCI。）

## 3. 验收（三条硬指标）

| 指标 | 判据 | 怎么查 |
|---|---|---|
| 镜像出来了 | `bin/targets/qualcommax/ipq50xx/*tplink_wta301*squashfs-sysupgrade.bin` 时间戳晚于本次构建 | `ls -lt` |
| LuCI 真在里面 | manifest 里出现 `luci-base` / `uhttpd` / `luci-theme-bootstrap` | `grep -c luci *manifest` |
| **rootfs 不超槽** | squashfs 实际长度 ≤ `0xbc0000`（12,320,768 B），否则用 `mk_op_pack.py --rlen 0xc00000` | `make-release.sh` 第 3 步会硬报错 |

> 槽位规则见 `docs/P3-PACK-CONTRACT.md` §10。P3 的 squashfs 是 8,244,224 B，
> 余量 4.1 MB；LuCI 全家桶通常 +3～4 MB，**贴边风险**是 P5 唯一的技术风险点（R12 变体）。

## 4. 重打包与复核

```sh
wsl -d Ubuntu2404 -u root bash /root/make-release.sh     # 自动：解包→mk_op_pack→UBI→flash_cmds→指纹
```

产出仍落在 `work/images/v25.12.6-P3/`（目录名沿用 P3；文件名里的长度会随 `--rlen` 变）。
复核项与 P3 完全一致：

- `+0x90` = md5(mtd4)，`+0xa0` = md5(kernel[0:0x480000] ‖ rootfs[0:RVERIFY])，
- UBI 卷名必须是 `rootfs_data`、15 PEB、`reserved_pebs 13`、autoresize，
- `ath11k/{IPQ5018,QCN6122}/hw1.0/board-2.bin` 的 md5 必须仍等于 S7 的 `78f5b21b…` / `e4904f13…`。

## 5. 不做的事

- 不加 `ipq-wifi-*`（会覆盖我们的 board-2.bin；本板 BDF 与 S7 逐字节一致，直接复用）。
- 不加 `kmod-qca-nss-dp`（已决定纯 CPU 转发，见 R14）。
- 不在 P5 顺手改 DTS/bootargs（单一变量：P4 首验通过之后再谈优化）。

## 6. 实测结果（2026-11-05 05:27，`make -j8` MAKE_EXIT=0）

| 项 | P3 | P5 | 判据 |
|---|---|---|---|
| manifest 包数 | 147 | **182**（S7 178） | 全在 |
| LuCI | 无 | `luci-base` `luci-mod-admin-full` `luci-theme-bootstrap` `luci-app-firewall` `uhttpd` `cgi-io` ✓ | 逐条 grep manifest |
| zram | 无 | `zram-swap` + `kmod-zram` ✓ | 同上 |
| kernel ITB | 4,276,536 B | 4,277,940 B（+1,404，zram 模块） | ≤ 0x740000 ✓ |
| squashfs | 8,244,224 B | **8,713,216 B** | ≤ 0xbc0000 ✓，余量 3.6 MB |

产物 `work/images/v25.12.6-P5/`，`tools/verify_pack.py` **PASS**（`+0xa0` = `1abdd945…`）。
rootfs 内 `90_wta301`(3,310 B) / `12-wta301-caldata`(4,586 B) / 两个 `board-2.bin`
（`78f5b21b…` / `e4904f13…` = S7 逐字节一致）全部就位，无 `nss`、无 `ipq-wifi-*`。

### 已知非确定性（无害，但要知道）

`mkfs.ubifs`/`ubinize` 在 UBIFS superblock 与 UBI EC 头里写时间戳，**同参数两次生成的两个
空 overlay 镜像字节不同**（实测 `SOURCE_DATE_EPOCH` 在本机 host 工具上不生效）。
因此：**空 overlay 镜像不可能字节级复现**，判据只能看结构（卷名/PEB 数/autoresize/vtable CRC），
由 `tools/verify_pack.py` 检查；归档指纹以 `SHA256SUMS` 为准（成品一旦归档就是固定的）。
kernel/rootfs/tphdr 三个区不受影响（都由 `mk_op_pack.py` 用固定字节补齐），crc32 只随内容变。
