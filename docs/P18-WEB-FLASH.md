# P18 — 网页刷机（无 TTL）+ 原厂官网包直刷

前置：P17 已验证（kernel `4131c6d0` / rootfs `0112e226` / ubi `c8ca6022` / tphdr `d343b30c`）。

---

## 0. 本轮的起因（用户质问，原话）

> 什么玩意，想刷我还得自己输入命令？假设我没有 ttl，不应该是 web 界面选择固件，
> 点击刷入，重启就完事了吗？？而且为什么我们的 ubootkit 不支持直接刷写原厂

三条都是对的。查证结果：

| 质疑 | 查证结论 |
|---|---|
| 得自己输命令 | ✅ 成立。`SOP-FLASH.md` 8 节没有一节提网页，刷写就是 TTL 6 行命令 |
| 没有 TTL 怎么办 | ❌ **本来可以不用 TTL**，见 §2，是**我把入口关掉的** |
| 为什么不认原厂包 | ✅ 成立。`fw_dec.c` 里易展容器（`55aa4c5e`）直接 `return FW_TYPE_UNKNOWN` |

---

## 1. 已确认存在的能力（读源码，不是推测）

`src/u-boot-2016/` 里 Web 刷机骨架**早就齐全**：

| 能力 | 位置 | 状态 |
|---|---|---|
| HTTP 服务 | `include/configs/ipq5018.h:547` `#define CONFIG_HTTPD` | ✔ |
| 内嵌上传页 | `failsafe/fsdata/index.html`（21,490 B） | ✔ |
| `/upload` `/result` | `failsafe/modules/upgrade.c`，7 种 upgrade_type | ✔ |
| 按 TP 表写固件 | `board/qca/arm/common/failsafe.c:752` `tpimg_parse`+`tpimg_write` | ✔ |
| bootipq 失败自动进网刷页 | `board/qca/arm/common/cmd_bootqca.c:1019` | ✔ |
| 网页终端 | `failsafe/modules/webterm.c` | ✔ |
| 空闲退出（30 s 没人连就继续启动） | `failsafe/failsafe.c:44` | ✔ |
| 网页上传统计 | `net/httpd.c:417` `"Content-Length:"` += `sizeof()-1` | ✔ 无 off-by-one |

板上 kit 实测可用命令（`help` 输出）：`httpd` `telnetd` `wget` `tplflash` `tplcheck` `tpluboot` `tftpboot` `tftpput`。

**所以缺的不是功能，是入口 + 一种容器格式。**

---

## 2. ★ 入口被我关掉了 —— 根因是 GPIO 号抄错，不是按键机制有问题

### 2.1 现场读数（决定性）

```c
/* ubootkit 里执行 */
md 0x01014004 1   → 01014004: 00000001     /* GPIO20 IN_OUT，bit0=1 高电平=未按下 */
md 0x01011004 1   → 01011004: 00000001     /* GPIO17，同上 */
md 0x01026004 1   → 01026004: 00000003     /* GPIO38，是输出脚 */
```

地址公式 `include/configs/ipq5018.h:98-100`：
`TLMM_BASE=0x01000000` · `GPIO_IN_OUT_ADDR(x) = TLMM_BASE + 0x4 + x*0x1000` ·
`gpio_get_value()` = `readl(addr) & 1`（`drivers/gpio/ipq_gpio.c:73`）。

### 2.2 真实按键号

`files/arch/arm64/boot/dts/qcom/ipq5018-wta301.dts:119-135`：

```dts
compatible = "gpio-keys";
key-reset { label = "reset"; gpios = <&tlmm 20 GPIO_ACTIVE_LOW>; linux,code = <KEY_RESTART>; };
key-wps   { label = "wps";   gpios = <&tlmm 17 GPIO_ACTIVE_LOW>; linux,code = <KEY_WPS_BUTTON>; };
```

P17 已在 Linux 侧现场实测 `pressed`/`released`。

### 2.3 当初为什么删掉 `/keys`

`src/u-boot-2016/arch/arm/dts/ipq5018-tplink-wta301.dts` 原注释（已替换）：

> The reset@27 / wps@38 pair this file used to carry was **copied from
> ipq5018-cmcc_mr3000d-ci.dts, i.e. from a DIFFERENT board**. GPIO38 is not a
> button on the WTA301: it floats low, so is_any_button_pressed() saw "wps" held
> down on every single boot and do_httpd_check() therefore always dropped into
> "wps button pressed, enter web failsafe mode after: 3 2 1 0" + httpd.
> With no /keys node, fdt_path_offset(fdt, "/keys") fails fast and the button
> path is skipped.

**错的是 GPIO 号（27/38 → 20/17），不是按键机制。** 当时把整个节点删了。

### 2.4 正确的触发链

```
common/main.c:95        do_httpd_check();
lib/ipq_api.c:209       is_any_button_pressed_for_enough_time()
                          → fdt_path_offset(fdt, "/keys")
                          → fdt_for_each_subnode: 读 "gpio" / "active_level"
                          → is_button_pressed(): 连续两次读数一致才算按下
                          → LED 闪 + 倒计时 "3 2 1 0"
                          → run_command("httpd")   ← 网页刷机页
```

`is_button_pressed()`（`lib/ipq_api.c:75-85`）：
`button_pressed = (active_level == GPIO_ACTIVE_LOW) ? GPIO_OUT_LOW : GPIO_OUT_HIGH`，
然后读一次、`udelay(10000)`、再读一次，两次相同才返回 true。

### 2.5 本轮改动

`ipq5018-tplink-wta301.dts` 加回 `/keys`，GPIO 用**实测值** 20/17：

```dts
keys {
    compatible = "gpio-keys";
    reset { gpio = <20>; func = <0>; drvstr = <GPIO_8MA>;
            pull = <GPIO_PULL_UP>; oe = <GPIO_OE_DISABLE>;
            active_level = <GPIO_ACTIVE_LOW>; };
    wps   { gpio = <17>; ... 同上 ... };
};
```

`pull = GPIO_PULL_UP`（bindings `dt-bindings/qcom/gpio-ipq5018.h` 里 = 2，
注意 `gpio-ipq40xx.h` 里也是 2，而 `gpio-ipq5332.h` 是 3 —— 别混）。
内核侧用 `bias-disable`；u-boot 侧加上拉多一层保险，因为**实测空闲就是 1**，
加内上拉后即使外部上拉缺失也不会误判成按下。

`gpio_tlmm_config()`（`drivers/gpio/ipq_gpio.c:29-47`）位域：
```
val = pull | func<<2 | drvstr<<6 | oe<<9 | (IPQ5018: od_en<<10 | sr_en<<11 | pu_res<<12)
```
`oe = GPIO_OE_DISABLE = 0` ⇒ 输入方向。预处理器展开实测：
`gpio=<20> func=0 drvstr=3 pull=3 oe=0 active_level=1`。

---

## 3. ★ 原厂官网包直刷（`55aa4c5e` 易展容器）

### 3.1 两种容器的区别（实测）

| | 本板 flash 里的 TP 头 | 官网下载的原包 |
|---|---|---|
| 前 4 字节 | `00 00 01 00` | `00 00 01 00`（相同）|
| +0x04 | `55 aa 9d d1` | **`55 aa 4c 5e`** |
| 小端 u32 | `0xD19DAA55` | `0x5E4CAA55` |
| 几何字段 +0x48..+0x64 | 有 | **没有** |

`fw_dec.c` 原来：

```c
case HEADER_MAGIC_TPLINK1:
    if (U32_DATA_AT_OFFSET(addr + 0x4) == HEADER_MAGIC_TPLINK2)
        return FW_TYPE_TPLINK;
    return FW_TYPE_UNKNOWN;          /* ← 4c5e 死在这里 */
```

全源码 grep `4c5e` = **0 命中**（上游 uBootKit 也没做）。

### 3.2 官网包内部是平铺明文（不是加密）

实测 `work/out-final/fw_202.bin`（TP-Link 官网 2.0.2，17,302,016 B）：

```
0x000000..0x000200    512 B 包头（magic + 签名/摘要，无几何字段）
0x000200..0x060000    LZMA-Alone（原厂二级 u-boot），解压出 0x5ae2c 字节
0x060200..            kernel FIT，magic d00dfeed（前面 0x200 字节为 0）
0x460200..            rootfs squashfs，magic hsqs（同样前置 0x200）
```

判定值：`FIT totalsize = 0x2859f8`（`be32(fit+4)`）；`squashfs bytes_used = 0xbae8a5`
（`le64(sqfs+0x28)`）。`FIT` 末尾到 `0x460200` 之间 **0x17a608 字节实测全 0xFF**
（逐字节核过）⇒ kernel 窗口可以安全地按 `0x400000` 算。

### 3.3 为什么不用 PC 侧转换

上一版做法是 `work/out-final/mk_pack_from_factory.py` 在电脑上抽出三段、套上
`55aa9dd1` 头、再传到板子。问题：**没有 TTDP 的人根本走不了这条路**，
而且和"网页点击刷入"的体验目标矛盾。

板侧做法（`tpimg_parse_factory()`，新增 ~110 行）：

1. 校验 `magic == 55aa4c5e`
2. 校验 `0x60200` 处是 FIT magic，读 `totalsize ≤ 0x400000`
3. 校验 `0x460200` 处是 `hsqs`，读 `bytes_used`，对齐到 `0x20000`
4. **把 `kernel_len` 直接定成 `TPFACT_KERNEL_AREA = 0x400000`**
5. 填 `tpimg_info`，几何字段用本板真值（`WTA301_*_OFF/LEN`）
6. 之后完全复用 `tpimg_build_header()` + `tpimg_write()`

关键点 4：`tpimg_build_header()` 算的是

```c
md5(info->kernel, kernel_len + rootfs_verify_len)    /* tplink_tpimg.c:213 */
```

它假定 **kernel 后面紧跟 rootfs**。原厂包里 `0x60200 + 0x400000 == 0x460200` 恰好成立，
所以 `kernel‖rootfs` 在 RAM 里天然连续 —— **不用拷 17 MB，也不用改 md5 算法**。

### 3.4 安全边界（一处都不放松）

| 检查 | 值 | 不通过 |
|---|---|---|
| FIT magic | `0xEDFE0DD0` | 拒绝 |
| FIT totalsize | `≤ 0x400000` | 拒绝 |
| squashfs magic | `hsqs` | 拒绝 |
| `bytes_used` 范围 | `0xb00000 .. 0xc00000` | 拒绝 |
| 对齐后长度 | `≤ 0xC00000` | 拒绝 |
| 文件是否够长 | `≥ 0x460200 + vlen` | 拒绝 |
| 写入目标 | **硬编码** `WTA301_KERNEL_OFF/ROOTFS_OFF/TPHDR_OFF` | 上传方无法指定 |
| `+0x90`（u-boot 槽 md5） | **保留 flash 现值**，不用上传文件里的 | 见下 |

`+0x90` 保留现值的理由（`tplink_tpimg.h` 原注释）：上传文件里不含 u-boot 槽，
算不出正确摘要；而现行头能让我们从 A 槽启动，说明它的 `+0x90` 已被一级验过。

---

## 4. 改动清单

| 文件 | 改动 |
|---|---|
| `src/u-boot-2016/arch/arm/dts/ipq5018-tplink-wta301.dts` | 加回 `/keys`，GPIO 20/17（实测值），替换掉那段"故意没有 /keys"的注释 |
| `src/u-boot-2016/include/failsafe/fw_dec.h` | 新增 `FW_TYPE_TPLINK_FACTORY`、`HEADER_MAGIC_TPLINK_MESH = 0x5E4CAA55`，改写 4c5e 的注释 |
| `src/u-boot-2016/board/qca/arm/common/fw_dec.c` | `check_fw_type` 认 4c5e；`fw_type_to_string` 加一行 |
| `src/u-boot-2016/board/qca/arm/common/tplink_tpimg.c` | 新增 `tpimg_parse_factory()`（~110 行，含完整理由注释） |
| `src/u-boot-2016/include/failsafe/tplink_tpimg.h` | 声明 `tpimg_parse_factory()` |
| `src/u-boot-2016/board/qca/arm/common/failsafe.c` | validate/write 两个 switch 加 `FW_TYPE_TPLINK_FACTORY` 分支；ART 的 wrong-type 列表补一项 |

---

## 5. 构建记录

```
CROSS_COMPILE = src/staging_dir/toolchain-arm_cortex-a7_gcc-5.2.0_musl-1.1.16_eabi/bin/arm-openwrt-linux-muslgnueabi-
make ipq5018_tplink_wta301_defconfig
make -j1                     # 必须串行，见 work/scratch/build_j1.sh 顶部注释
```

踩到并修掉的坑：
1. **DTS 块注释里嵌套 `/* */`** —— 我在注释里写 `{ ... }  /* KEY_RESTART */`，
   提前结束块注释 → `Error: ipq5018-tplink-wta301.dts:57.5-6 syntax error`。
   改成不带 `/*` 的写法。
2. `dtbtable.S: No such file or directory` —— 首次 make 在 `defconfig` 后需要再跑一次
   （`dtbtable.S` 是 `%.dtb.comb.S` 规则的副作用产物）。

产物：`u-boot.bin` 545,736 B（P17 是 543,448 B，+2,288 B）
槽镜像：`work/images/kit-p18/uboot_slot_0x40000.bin` 262,144 B
  · LZMA preset9 → 218,453 B（83.3% 槽）
  · slot md5 `89d2628f3660f585f4f88bd780fe10b1` · crc32 `376cb813`
  · round-trip 逐字节一致 ✔ · 首字是 ARM 分支 ✔

预处理器展开验证（不是猜）：
```
keys { compatible = "gpio-keys";
  reset { gpio = <20>; func = <0>; drvstr = <3>; pull = <3>; oe = <0>; active_level = <1>; };
  wps   { gpio = <17>; ... };  }
```
`strings u-boot.bin` 里有 `TP-Link Official Firmware (factory container)`、
`tpimg: factory container detected` ⇒ 新代码确实编进去了。
`dtb_combined.bin.gz` 里有 `gpio-keys` + `active_level` ⇒ `/keys` 确实进了 DTB。

---

## 6. 验收清单

| # | 项 | 判据 |
|---|---|---|
| 1 | 刷写 §7 的 5 条命令全 ok | crc32 = `376cb813` |
| 2 | `tplcheck` 全分区自检 | 无 FAIL |
| 3 | 重启进 Linux | `root@` |
| 4 | **按键进网刷页** | 按住 reset 上电 → 串口出 `reset button pressed, enter web failsafe mode after: 3 2 1 0` |
| 5 | 网页可访问 | `http://192.168.1.1/` 出 `Web failsafe UI` |
| 6 | **按键不误触发** | 不按键上电 → 直接进 Linux，无 `button pressed` |
| 7 | 网页刷 op 包 | 上传 `op_single_0x4800000.bin` → 写入 → 重启进 Linux |
| 8 | 网页刷官网包 | 上传 `fw_202.bin` → 识别为 factory container → 写入 → 重启进原厂 |
| 9 | 空闲退出 | 进网页后 30 s 不操作 → 自动继续启动 |

第 6 项是本轮最关键的反向验证：GPIO 号一旦再错就会退回"每次上电卡网刷页"。

---

## 7. 刷 kit 的命令（一次性，仍需 TTL）

```
printenv ;tftpboot 0x44000000 uboot_slot_0x40000.bin
printenv ;crc32 0x44000000 0x40000                     ← 期望 376cb813
printenv ;tpluboot 0x44000000 0x40000                  ← dry run
printenv ;tpluboot 0x44000000 0x40000 write            ← 真写 + 重签 +0x90
printenv ;tplcheck
```

**这是最后一次需要 TTL 的刷写。** 之后 kit 自带网页刷机，日常升级不用串口。

---

## 8. 顺带修掉的刷写耗时问题

用户问"为什么刷写那么久，就几 mb 的镜像"。实测账（`work/evidence/p16-flash.log`）：

| 项 | 量 |
|---|---|
| 实际擦除 | **52.6 MiB**（kernel 4.5 + rootfs 11.75 + **UBI 36.25** + tphdr 0.125）|
| 实际写入 | 18.25 MiB（UBI 只写 1.875 MiB 但要擦满 36.25）|
| 回读校验 | 18.25 MiB |
| u-boot `crc32` | 18.25 MiB（逐字节实现）|

而 `coldflash.py` 的 `drain(t)` **恒等满 t 秒**，`nand erase` 4.0 s、`nand write` 7.0 s、
`nand read` 4.0 s、`crc32` 4.0 s ⇒ **4 分区光等待 86 s**，与实际快慢无关。

本轮改法：`send()` 加 `until`/`need`，**成功标志 + 提示符同时出现**才提前返回
（只要提示符会在两种情况下误判：缓冲里遗留的提示符、命令被截断后提前回提示符）。
超时上限：erase/write 120 s、read/crc32 90 s、其它命令 120 s。
`ok` 判定不变，所以**最坏情况是误报 FAIL 并中止，不会静默写错**。

---

## 9. ★ 包格式：网页刷机必须用紧凑包（2026-11-06 实测）

这一条是补 §6 验收第 7 项的坑。原文档只写「上传 `op_single_0x4800000.bin`」，
实测**会被后端拒绝**：

```
POST /upload  →  {"status":"fail","info":{"type":"invalid_tplink_firmware",
                 "reason":"rootfs_too_big"}}
```

### 9.1 两种包不能混

| 包 | 尺寸 | 布局 | 用途 |
|---|---|---|---|
| `op_single_0x4800000.bin` | `0x1380000` 19.5 MB | 按**绝对 NAND 地址**摆位，kernel 与 rootfs 之间 `0x2C0000` 填 `0xFF` | TTL：`nand erase/write 0x4800000 0x1380000` |
| **`op_wta301_firmware_web.bin`** | **`0x1060000` 16.38 MB** | tphdr‖kernel‖rootfs **紧贴** | **网页刷机** |

### 9.2 代码依据

`board/qca/arm/common/tplink_tpimg.c:152,158`：

```c
info->kernel = h + TPIMG_HDR_LEN;          /* +0x20000 */
info->rootfs = info->kernel + klen;        /* ← 假设紧贴 */
rlen = avail - klen;                       /* avail = size - 0x20000 */
...
if (rlen > WTA301_ROOTFS_SLOT) {           /* 0xC00000 */
    *err = "rootfs_too_big";
```

稀疏包代入：`rlen = 0x1380000 - 0x20000 - 0x480000 = 0xEE0000 > 0xC00000` ⇒ 拒绝。
即便尺寸放过，`info->rootfs` 也会指向空隙里的 `0xFF`，写进去是坏数据。

### 9.3 生成方法（已有工具，勿重造）

```bash
python work/out-final/flash_release.py --dir <镜像目录> --mk-web
#  -> <镜像目录>/op_wta301_firmware_web.bin
#     整包 = tphdr(131072) + kernel(4718592) + rootfs(12320768)
#     size 17170432 (0x1060000)   md5 837a9a553886426ac8b184109bf1b913
```

P17 的规范指纹：`size 17170432` · `md5 837a9a553886426ac8b184109bf1b913` · `crc32 bfac6bcb`

### 9.4 前端那个「最大 17 MB」不是随手写的

`failsafe/fsdata/index.html` 的 `setFile()`：

```js
if(f.size>17*MB){ status("st","err","文件过大", ...); return; }
```

17 MiB **正好容得下** 16.38 MiB 的紧凑包。所以这是刻意的，不是写小了。
后端真实上限远大于此（`net/httpd.c:108` 上传缓冲在 `0x41000000`，往上到 `0x50000000`
约 240 MB 可用），前端只是不许选超大的文件。

### 9.5 实测记录

```
POST /upload  → success  size 17170432  md5 837a9a55…
                tpimg: header says kernel 0x480000 @0x04880000, rootfs verify 0xbc0000 @0x04fc0000
                tpimg: kernel magic 0xd00dfeed, rootfs magic 0x68737173
POST /result  → nand erase 0x4fc0000 0xbc0000 / write 12320768 B OK
                nand erase 0x4800000 0x20000  / write 131072 B OK
                tpimg: A slot written and header re-signed
                {"status":"success","info":{"reboot":false}}
```

一键工具：`tools/web_flash.py`（`--dry` 只校验）。

## 10. 按键：必须按住 40 秒以上（2026-11-06 更正）

`do_httpd_check()` 在 `common/main.c:88-97`，位置是 `bootdelay_process()` **之前**，
即 `RTL8367S: 4 panel PHYs up, eth0, eth1` 之后、`Hit any key to stop autoboot` 之前。
实测这两者只隔 1 秒：

```
[38.7s] RTL8367S: 4 panel PHYs up, HSGMII trunk to port 6 up / eth0, eth1
        ←  do_httpd_check() 在这一刻（上电后约 39 秒）
[39.8s] Hit any key to stop autoboot: 3 2 1 0
```

⇒ **按住 reset 上电后要一直按到约 40 秒后红灯亮**，按 8~10 秒毫无作用
（那时还在初始化 DDR 与交换机）。按到进 Linux 会被 preinit 判成 failsafe
（红绿灯交替闪 = `OpenWrt-failsafe`），不是网刷页。

排除项（都实测正常，不是故障点）：
`gd->fdt_blob = 0x49a14004` 有效 · `fdt print /keys` 属性齐全（`gpio=<0x14>`=20、
`active_level=<0x1>`）· 未按时 GPIO20 读 `0x00000001`、按住读 `0x00000000`
