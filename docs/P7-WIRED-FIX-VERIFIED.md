# P7 — 有线以太网修复后真机端到端验证

日期：2026-11-05
包：`work/images/v25.12.6-P7/`（`make-release.sh` 产出，`/root/rel/pack`）
回滚资产：`work/backup/FROZEN-S7-20261105/`（kernel `53bd0490` / rootfs `c2e227c6` / tphdr `3ccbcfc4`）
B 槽 mtd10/mtd11、一级 u-boot、`boot_flag` 全程**未动**。

> `/proc/net/dev` 的 rx/tx 第一列是**字节**、第二列才是包。本文所有 `eth0 rx=…` 均指字节数。

---

## 0. 本次唯一变量

```
CONFIG_PCS_QCA_UNIPHY:  n  ->  y
```

其余（kernel 6.12.112 源码、rootfs、DTS、buildargs、UBI 卷名、刷写地址）**逐字节不变**。
证据：rootfs crc32 与 P6 完全相同（`64fae03b`），只有 kernel crc32 从 `0cfe65c5` 变为 `4131c6d0`。

---

## 1. 四件套指纹（刷入前，`FINGERPRINT.json`）

| 文件 | size | crc32 |
|---|---|---|
| `op_kernel_0x480000.bin` | 4,718,592 | `4131c6d0` |
| `op_rootfs_0xbc0000.bin` | 12,320,768 | `64fae03b` |
| `op_tphdr_0x20000.bin` | 131,072 | `37c15af3` |
| `ubi_rootfs_data3_wta301data.img` | 1,966,080 | `2942f3a6` |

---

## 2. 刷写：每区三列校验（本地 = RAM = NAND 回读）

按 `flash_cmds.txt` 逐条执行，**每条先过 `work/out-final/guard.py check`（20/20 放行）**，
每区写完 `nand read` 到旁址 `0x43000000` 再 `crc32`，与本地文件比对：

| 区 | 地址/长度 | 本地 crc32 | RAM crc32 | NAND 回读 crc32 | 结论 |
|---|---|---|---|---|---|
| kernel | `0x4880000` / `0x480000` | `4131c6d0` | `4131c6d0` | `4131c6d0` | ✅ |
| rootfs | `0x4fc0000` / `0xbc0000` | `64fae03b` | `64fae03b` | `64fae03b` | ✅ |
| ubi overlay | `0x1bc0000` / `0x1e0000`（erase `0x2440000`） | `2942f3a6` | `2942f3a6` | `2942f3a6` | ✅ |
| tphdr | `0x4800000` / `0x20000` | `37c15af3` | `37c15af3` | `37c15af3` | ✅ |

P6 时期 kernel 为 `0cfe65c5`，本次回读为 `4131c6d0` ⇒ **确实写入了新内核**，非旧值残留。

---

## 3. 冷启动端到端判据（断电冷启动，`work/evidence/p7-coldboot.log`）

| # | 判据 | 实测 | 结论 |
|---|---|---|---|
| 1 | 系统版本 | `DISTRIB_RELEASE='25.12.6'` / `r33311-981c978eff` | ✅ |
| 2 | 内核版本 | `Linux version 6.12.112` | ✅ |
| 3 | 引导链走 A 槽 | `tplboot: image_2 kernel 0x480000 @0x04880000 -> 0x44000000` | ✅ |
| 4 | **有线连通** | `ping -c 3 192.168.1.100` → 3 received, **0% packet loss** | ✅ |
| 5 | 交换机识别 | `found an RTL8367S switch`；`lan1..lan5` 全部注册 | ✅ |
| 6 | CPU 口收发 | `eth0` rx 29803 B / tx 10245 B 持续增长；`lan1` tx 8495 B | ✅ |
| 7 | overlay | `/dev/ubi0_0 27.9M，68.0K 已用` | ✅ |
| 8 | Wi-Fi 双射频 | `phy0-ap0` ch1/2.4G，`phy1-ap0` ch36/5G 80MHz | ✅ |
| 9 | PCS 驱动认领时钟 | `gcc_uniphy_{tx,rx,sys,ahb}_clk` enable_cnt 1~2，`is_enabled=Y`，consumer `ethernet-pcs@98000` | ✅ |

**9/9 通过。**

---

## 4. 与 P6 的决定性对照

| 指标 | P6（`PCS_QCA_UNIPHY=n`） | P7（`=y`） |
|---|---|---|
| `ping 192.168.1.100` | **100% packet loss** | **0% packet loss** |
| `eth0` rx | **0** | 29803 B 且持续增长 |
| `lan1` tx | **0** | 8495 B 且持续增长 |
| `gcc_uniphy_tx_clk` | `enable_cnt=0  is_enabled=N` | `enable_cnt=2  is_enabled=Y` |
| `gcc_uniphy_rx/sys/ahb_clk` | `enable_cnt=0  is_enabled=N` | `enable_cnt=1..2  is_enabled=Y` |
| consumer | `deviceless` | `ethernet-pcs@98000` |

---

## 5. 根因（已实证）

`=n` 时没有任何驱动认领 `qualcomm,ipq5018-uniphy` 节点，于是：

1. `clk_disable_unused()`（dmesg 可见 `clk: Disabling unused clocks`）把
   `gcc_uniphy_{ahb,rx,tx,sys}_clk` 四个门控时钟关死；
2. UNIPHY SerDes 因此没有 125 MHz 参考，**到 RTL8367S 的 SGMII/HSGMII 通道不工作**；
3. 交换机侧一切正常（`RTL8367S: 4 panel PHYs up, HSGMII trunk to port 6 up`，
   `lan1` rx 能看到线缆来的帧），但 CPU 口物理收不到也发不出；
4. 于是 `eth0` rx=0、`lan1` tx=0 —— 与 P6 实测完全一致。

`=y` 时 PCS 驱动 probe、`devm_clk_bulk_get` 拿到这四个时钟并 enable，
同时按 SGMII 编程 SerDes，通道打通。

### 5.1 判据陷阱（记录以免重犯）

`gmac1_tx_clk_src` 在 `=y` 且链路 1 Gbps Up 的情况下**仍读 0 Hz**。
这是 clk 递归 rate 计算的读数假象，**不是**可用判据。可用判据是
`gcc_uniphy_*_clk` 的 `enable_cnt` / `is_enabled` 与 `eth0` rx 字节数。

### 5.2 外部依据

[OpenWrt PR #22381 "qualcommax: networking rework"](https://github.com/openwrt/openwrt/pull/22381)
是 `drivers/net/pcs/pcs-qca-uniphy.c` 的来源，明确列 `ipq50xx` 已测试
（QSGMII/PSGMII/SGMII 等 PHY mode 均打勾），并记有
"UNIPHY clk doesn't scale correctly on speed/mode change — Fixed"。
即**上游设计就是让 PCS 驱动持有并启用 uniphy 时钟**；`=y` 是回归上游设计，不是私改。

该 PR 的故障栈里同样出现 `clk_disable_unused_subtree -> clk_branch2_disable`，
与 §5 机制吻合。

---

## 6. 6.12 移植补丁

上游 `pcs-qca-uniphy.c`（6.18）用到 `clk_hw_recalc_rate()`（v6.18 新 API）且
`probe()` 把指针当 `int` 返回，6.12 编不过。`files/drivers/net/pcs/pcs-qca-uniphy.c`
做了最小等价移植：

- `clk_hw_recalc_rate(clk, 0)` → `clk_hw_get_rate(clk)`
  （两者都走 `__clk_recalc_rates(core, false, 0)`；`gmac1_*_clk_src` 带
  `CLK_GET_RATE_NOCACHE`，返回值一致）
- `probe()` 改用 `devm_fwnode_pcs_add_provider()` + `IS_ERR()` 判断

该补丁**只在 6.12 需要**；将来目标升到 6.18 即可整文件删除。

---

## 7. 复现命令

```sh
# 出包（WSL, root）
wsl -e bash /root/mrel.sh          # -> /root/rel/pack/{4 个 .bin, FINGERPRINT.json, flash_cmds.txt}

# 刷写：断电冷启动抢 u-boot + 立即 TFTP + 逐区 crc32
python work/scratch/uboot_flash.py \
  --cmds <flash_cmds.txt> --fp <FINGERPRINT.json> --log work/evidence/p7-flash1.log

# 冷启动抓全量启动日志
python work/out-final/plug_mijia.py cycle
python work/scratch/bootcap.py 7001 95 work/evidence/p7-coldboot.log

# 判据
python work/scratch/probe_now.py 7001 \
  "uname -r~~ping -c 3 -W 2 192.168.1.100~~cat /proc/net/dev | grep -E 'eth0|lan1'~~df -h /overlay" 4
```

---

## 8. 运维坑（本板实测，务必遵守）

1. **u-boot 的交换机开机后约 1~2 分钟就不再转发**
   （Windows 侧 `ping 192.168.1.1` 变 "无法访问目标主机"）。
   ⇒ TFTP 必须在抓到提示符后**立刻**发，不能分多次调用慢慢来。
   `work/scratch/uboot_flash.py` 已内置"cycle → grab → 立即 tftpboot"一气呵成。
2. **TFTP 服务必须用 `schtasks` 独立注册**，不能 `Start-Process`：
   随 SSH 会话结束会被回收，表现为 u-boot 侧 `Loading: *` 无响应，
   而 ping 正常（ICMP 通、UDP/69 无人监听）。
   已注册任务 `wta301tftp`。
3. **抢 u-boot 只发单字节 `s`、看到 `IPQ5018#` 立即停**。
   连续洪泛 `slp` 超过 90 秒会把 u-boot 打挂（提示符后继续灌字符 →
   `cmd  is blocked` 循环，`bootipq` 失效），只能断电恢复。
4. `nand erase` 大区（`0x2440000`）耗时较长，等待要给足 20s，否则后续命令被吞。
