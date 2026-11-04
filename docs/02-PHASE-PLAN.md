# 02 阶段计划

**原则**：一次只改一个变量（`AGENTS.md` §2）。每阶段有明确**通过条件**，不通过不进下一阶段。
**P1–P3 全程不碰板子**；P4 起需上电。

---

## P0 规划 ✅

| 项 | 产出 |
|---|---|
| 迁移分析 | `docs/00-MIGRATION-ANALYSIS.md` |
| 风险登记 | `docs/01-RISK-REGISTER.md` |
| 外部证据 | `docs/03-EXTERNAL-EVIDENCE.md` |
| 上游事实快照 | `pin/x2512-facts.json` |
| S7 基线快照 | `pin/s7-baseline.json`（引用 FROZEN-S7） |

**通过条件**：四份文档 + 两份 pin 落库，首次提交。

---

## P1 补齐缺口 + 取得上游参数（不碰板子）

**目标**：把「改之前必须先知道」的东西全部拿到并落库。

| # | 任务 | 产出 | 通过条件 |
|---|---|---|---|
| P1.1 | **反编译实际 DTB，导出 `.dts` 源**（解决坑 1 / R2） | `patches/s7-actual-dtb.dts`（1,289 行） | 反编译结果与源 dts diff 逐条列出 |
| P1.2 | 源 dts vs 实际 DTB 差异表 | `docs/04-DTB-SOURCE-DRIFT.md` | 每条差异标注"已知无害/未验证" |
| P1.3 | 克隆 25.12.6 源码树（sparse：qualcommax + mac80211 + generic） | `/root/ow2512` | `git describe` = v25.12.6 |
| P1.4 | 记录 25.12.6 内核/kmods/工具链参数 | `pin/x2512-facts.json` | 内核 6.12.112、kmods hash、toolchain gcc 14.3.0 |
| P1.5 | 逐个核对 7 个参照设备的 DTS，提取可复用段 | `docs/05-UPSTREAM-REFERENCE.md` | 列出我们可搬的节点与不可搬的理由 |
| P1.6 | 抓取 S7 当前 154 个版本匹配的 apk（防漂移失效） | `pin/apk-s7-frozen/` | sha256 清单 + 数量核对 |

**预计**：外部检索 30 min · 克隆 20 min · 差异分析 60 min · apk 抓取 20 min

---

## P2 造 DTS + 编内核（不碰板子）

| # | 任务 | 通过条件 |
|---|---|---|
| P2.1 | 以 **S7 实际 DTB 语义**（mode 2、双射频 okay）写 25.12.6 版 `ipq5018-wta301.dts` | `dtc` 编译 0 error |
| P2.2 | 写 `target/linux/qualcommax/image/ipq50xx.mk` 的 `Device/tplink_wta301` | `make menuconfig` 能看到 `tplink_wta301` |
| P2.3 | `make kernel` 编出 Image | Image 尺寸 **≤ 0x740000**（R7） |
| P2.4 | 核对新内核的 `vermagic` 与随包模块一致 | 全部 `6.12.112` |
| P2.5 | 核对 ath11k 的 QCN6122 补丁确实编进去 | 内核里含 `qcn6122_regs` 符号 |

**通过条件**：Image 造出、尺寸合规、DTB 可编译、属性名与 6.12 对得上。

**注意**：`CONFIG_MODVERSIONS` / `CONFIG_MODULE_SIG` 若开着，模块必须与内核同次构建。

---

## P3 离线造包 + 打包（不碰板子）

| # | 任务 | 通过条件 |
|---|---|---|
| P3.1 | 用 25.12.6 官方 IB tarball 重拼 rootfs | rootfs 可解、包数与 manifest 一致 |
| P3.2 | 沿用 S7 的 `.its` 模板造 FIT | `mkimage` 成功，ITB 结构合法 |
| P3.3 | `mk_op_pack.py` 重算 TP 头 | `verify_op_pack.py` 全 PASS，`+0xa0` 自检通过 |
| P3.4 | 生成 FINGERPRINT.json + 离线预检 | `flash_release.py` 预检 PASS |

**通过条件**：四件产物齐备、预检 PASS、`+0xa0 = md5(kernel‖rootfs)` 成立。

---

## P4 真机验证：只验「能不能启动 + 有线通」（需上电）

**唯一变量**：整包从 S7 换成 25.12.6。

| # | 任务 | 通过条件 |
|---|---|---|
| P4.0 | **回退演练**：先用归档把 S7 刷回去一次 | 刷回后指纹与 FROZEN-S7 完全一致 |
| P4.1 | 刷入 25.12.6 包（四区 + 三重校验） | 每区 crc32 三列相等 |
| P4.2 | 串口观察启动 | 出现 `Please press Enter to activate this console` |
| P4.3 | `cat /proc/mtd` | 14 项、偏移/大小与预期一致（R6） |
| P4.4 | `ip link` / `ubus` 看口 | 至少 1 个 lan 口可通 |
| P4.5 | 电脑 ping 通板子 | 通 |

**通过条件**：P4.2–P4.5 全过 ⇒ 正式版基线成立。

**不通过的回退**：立即用 `work/backup/FROZEN-S7-20261105/` 刷回 S7，记录失败日志。

---

## P5 Wi-Fi 验证（需上电）

**唯一变量**：`&wifi` / `&wifi1` 的 `status` 与 `fw-memory-mode`。

| 步骤 | 内容 | 判据 |
|---|---|---|
| P5.1 | 只启用 2.4G（`wifi1` 保持 disabled） | `iwinfo` 出现 `phy0`，能连 |
| P5.2 | 加 5G（`wifi1` okay，mode 2） | `iwinfo` 出现 `phy1` |
| P5.3 | 内存观测 30 min | `free` 可用 > 10 MB，无 `oom-kill` |
| P5.4 | 若 OOM | 加 ring 缩减补丁（hzyitc `911-ath11k-reduce-dma-buffer`，注意 6.12 用 `EXTRA_CFLAGS` 有效） |

**降级顺序**：mode2 → ring 补丁 → 只留 2.4G → 纯有线。

---

## P6 sysupgrade 落地（需上电）

| # | 任务 | 依据 |
|---|---|---|
| P6.1 | `lib/upgrade/platform.sh` 加 `tplink,wta301)` case 走 `nand_do_upgrade` | `CI_KERNPART` 同名 mtd 直写 |
| P6.2 | `platform_check_image()` 处理 TP 头 | 现在上游是空函数 `return 0` |
| P6.3 | 端到端实测：LuCI 上传 → 重启 → 指纹变化正确 | — |

---

## 时间与依赖

```
P0 ✅
 └─ P1（P1.1 是 P2 的前置，P1.3 是 P2 的前置）
     └─ P2（P2.3 是 P3 的前置）
         └─ P3
             └─ P4（需上电；P4.0 回退演练不可跳过）
                 ├─ P5（Wi-Fi）
                 └─ P6（sysupgrade）
```

**预计总工时**：P1 约 2.5 h · P2 约 3 h（编译为主）· P3 约 2 h · P4 约 1 h（含上电等待）
· P5 约 1.5 h · P6 约 2 h。

---

## 复用清单（不要重造）

| 用途 | 现成工具 |
|---|---|
| 刷写 | `work/out-final/flash_release.py --apply --catch` |
| TFTP | `work/out-final/tftpd.py`（三星机上已在跑） |
| 串口 | `work/net/lap.py --ensure` → socket://127.0.0.1:7001 |
| 电源 | `work/out-final/plug_mijia.py {on,off,cycle}` |
| 打 TP 头 | `wta301-s7/scripts/mk_op_pack.py` |
| 验 TP 头 | `wta301-s7/scripts/verify_op_pack.py` |
| rootfs 重拼 | `wta301-s7/scripts/assemble-rootfs.sh`（换 IB tarball 与 manifest） |
| DTB 反编译 | `dtc -I dtb -O dts`（WSL `/usr/bin/dtc`） |
