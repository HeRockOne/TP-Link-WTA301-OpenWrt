# 01 风险登记

**分级**：🔴 阻塞（不解决不能进下一阶段）· 🟠 高（可能导致返工）· 🟡 中 · ⚪ 低

| # | 风险 | 级 | 概率 | 后果 | 触发信号 | 应对 |
|---|---|---|---|---|---|---|
| R1 | 6.12.112 上 ath11k 双射频 OOM | 🔴 | 高 | 无线不可用，只能有线 | 开机后 `free` 可用 < 10 MB、`dmesg` 出现 `Out of memory` / `oom-kill` | 降级链：mode2 → ring 缩减补丁 → 只留 2.4G → 纯有线 |
| R2 | 实际 DTB 的源缺失（源 dts ≠ 实际） | 🔴 | **已发生** | 无法复现构建，改动无依据 | 反编译 DTB 与源 dts diff 非空 | 以实际 DTB 反编译结果为基线，先补 `.dts` 源 |
| R3 | 内核 6.18 → 6.12 回退导致 DTS 属性不认 | 🟠 | 中 | 设备树部分节点失效（GPIO/LED/交换） | 启动日志缺 `qca8337` / `rtl8367s` 探测 | 逐属性对照 25.12.6 的 `ipq5018.dtsi` 与 7 个参照 DTS |
| R4 | RTL8367S 交换驱动在 6.12 的行为变化 | 🟠 | 中 | 有线不通 | `ip link` 无 lan/wan、`dmesg` 无 switch | 先只验 1 个口；必要时回退到 `dsa` / `swconfig` 对照 |
| R5 | 25.12.6 的 ImageBuilder 无人能离线重拼（缺 apk 缓存） | 🟠 | 中 | 无法产出可控 rootfs | `apk add` 报 no such package | 用 25.12.6 官方 IB tarball + 官方 repo 快照下载一次性缓存 |
| R6 | 内核 `qcom,smem-part` 与我们的 `fixed-partitions` 冲突 | 🟠 | 低-中 | 分区表错乱 → 有变砖风险 | `/proc/mtd` 与预期不符 | **P3 前必须离线核对**；刷写前 `nand read` 回读校验 |
| R7 | TP-Link TP 头字段（`WTA301_KERNEL_MAX=0x740000`）与新内核尺寸不匹配 | 🟡 | 中 | 引导失败 | u-boot 报 kernel_len 超限 | 新内核必须 ≤ 0x740000（7.25 MiB），6.12 内核通常更小 |
| R8 | 6.12 内核尺寸/布局变化导致 FIT 结构不同 | 🟡 | 中 | `bootm` 失败 | — | 沿用 S7 的 `.its` 模板，只换 kernel/DTB |
| R9 | UBI overlay 布局迁移时写坏回退资产 | 🔴 | 低 | 丢回退路径 | — | 迁移期间 `rootfs_data2` 一字节不写；UBI 红线段不碰 |
| R10 | snapshot 源的包在迁移期被清理 | 🟡 | 中 | S7 无法再装包 | 404 | 迁移前先把 154 个版本匹配的包抓下来冻结 |
| R11 | 刷入新固件后无法回退（u-boot 窗口抢不到） | 🔴 | 低 | 需 TTL 救砖 | 串口无响应 | 刷前确认二级 u-boot 窗口可抢（3 s），保留 S7 全套产物 |
| R12 | 迁移产物与 S7 混淆，误刷 | 🟡 | 低 | 覆盖基线 | — | 分离目录 + 指纹文件不同名 + 刷写前打印指纹 |

---

## 红线（继承 `wta301-s7` 与 `AGENTS.md` §5）

1. **永不写** `factory_boot`（0x0–0x3c0000）、`normal_boot`（0x4700000）、`boot_flag`（0x4000000）
2. u-boot 链接基址 **`0x49900000`**（`0x4a920000` = TTL 死）
3. 刷写顺序 **kernel → rootfs → ubi → tphdr**；tphdr 的 `+0xa0 = md5(kernel‖rootfs)` 必须最后写
4. 三重校验：本地 crc32 = RAM crc32 = `nand read` 到**另一**地址的 crc32
5. `mkfs.ubifs` **必须 `-F`**（SB flags 0x4）；`BIGLPT` 会 bad master node
6. 任何切断 TTL / 破坏回退路径的操作，先停下来问用户

---

## 迁移期间对 S7 的保护

| 保护 | 做法 |
|---|---|
| 产物隔离 | 本仓产物一律在 `build-*`，不进 `work/images/`；产出后另建目录 |
| 基线冻结 | `work/backup/FROZEN-S7-20261105/` + `SHA256SUMS`（已完成） |
| 板子状态 | 迁移的 P1–P3 全程不碰板子；P4 才上电 |
| 回退演练 | 刷机前先把 S7 从归档刷回一次，证明回退路径可用 |
