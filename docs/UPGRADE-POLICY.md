# 升级策略决策：不做 in-Linux 在线升级（附实证理由）

日期：2026-11-05
相关：`P9-SYSUPGRADE-EXTERNAL-EVIDENCE.md`（外部检索 + 板级差异表）

> ## ⛔ 本文结论已被 P28 推翻 —— 保留作历史记录
>
> 本文的结论是「不做 in-Linux `sysupgrade`」。**后来做了，而且做成了**：
> `docs/P28-SYSUPGRADE-IN-OS.md`（真机验证 OK=23 FAIL=0）。
>
> 当时判断错误在哪：把「kernel 分区声明 0x400000，而 FIT 实际 4,280,940 B」
> 当成了不可逾越的障碍。实际上只靠 **DTS 一个数字**（`0x400000` → `0x740000`）、
> 加上 `platform_do_upgrade()` 两个 case 就解决了，既不动 tphdr，也不动 B 槽。
>
> 本文仍有价值的部分：§二对「为什么原厂 sysupgrade 会破坏启动链」的分析是对的，
> 那次分析正是 P28 能一次做对的前提。**但结论不要照抄。**
>
> 另一个当时没看准的点：overlay 在独立 UBI 卷（`wta301data`）上，
> 所以 in-Linux 升级**自动保留配置和已装包** —— 这反而是 sysupgrade 的最大优势。

---

## 一、结论（**已过时，见顶部横幅**）

**WTA301 的固件升级继续走 TTL + 四件套流程**，不做 in-Linux `sysupgrade`。
理由不是"懒得做"，而是**做了会危及回退路径**，且收益不成立。下面全部有实证。

---

## 二、stock `sysupgrade` 已经是「安全失败」，不需要额外护栏

### 2.1 本板实测（`[本板实证]`）

```
root@OpenWrt:~# which mtd sysupgrade
/sbin/mtd
/sbin/sysupgrade
root@OpenWrt:~# mtd write /etc/openwrt_release firmware; echo rc=$?
Could not open mtd device: firmware
Can't open device for writing!
rc=1
root@OpenWrt:~# grep -c firmware /proc/mtd
0
```

`default_do_upgrade()` 的路子是 `get_image | mtd write - firmware`
（`lib/upgrade/common.sh:315`，`PART_NAME=firmware`）。
本板 `/proc/mtd` 14 项里**没有** `firmware`
⇒ `mtd` 在 `open()` 阶段就失败，**一个字节都没写**。

⇒ 家里误跑 `sysupgrade -n xxx.bin` 的结果是**报错退出，机器不动**。
不是砖。这一条已实证，无需再加护栏脚本。

（唯一遗憾是错误信息 `Could not open mtd device: firmware` 对用户不友好，
但它是"安全但不解释"，不是"危险"。）

---

## 三、为什么"好好做 in-Linux 升级"在本板上不成立

### 3.1 升级必须同时重写 tphdr，而 tphdr 在 Linux 侧**不可寻址**

`[本板实证]`：

```
root@OpenWrt:~# cat /proc/mtd | grep -iE 'tphdr|header'
root@OpenWrt:~#
```

tphdr 位于 flash 偏移 **0x4800000**，长度 0x20000，落在
`normal_boot`（0x4700000 + 0x40000）与 `kernel`（0x4880000）之间的空档里，
**没有对应的 MTD 分区节点**，所以 `/dev/mtdN` 里没有它，`mtd` 工具也碰不到。

而 tphdr 里的四个字段必须随内容更新：

| tphdr 偏移 | 内容 | 为什么必须更新 |
|---|---|---|
| `+0x5c` | `KERNEL_LEN = 0x480000` | 定长，一般不变得重算 |
| `+0x60` | `ROOTFS_LEN = 0xbc0000` | 同上 |
| `+0xa0` | `md5(kernel[0:0x480000] ‖ rootfs[0:0xbc0000])` | **kernel/rootfs 一变就变** |
| `+0x90` | tphdr 自身校验 md5 | 上面字段变了它也得变 |

⇒ **只要换了 kernel 或 rootfs，tphdr 的 md5 就必然失效** ⇒ u-boot 校验失败 ⇒ 落 B 槽。
所以"只写 mtd5/mtd6、不动 tphdr"的升级路径**在原理上不存在**。

### 3.2 把 tphdr 暴露成 MTD 分区，会动 mtd 序号 —— 这条红线不能踩

Linux 的 mtd 序号由**分区注册顺序**决定，而注册顺序来自 DTS `partitions` 子节点顺序。
插入 `tphdr@4800000` 之后，原来 `kernel=mtd5 / rootfs=mtd6` 有可能变成
`kernel=mtd6 / rootfs=mtd7`。

而本板 bootargs 是**写死**的：

```
root=/dev/mtdblock6 rootfstype=squashfs ...
```

（`wta301-2512/files/arch/arm64/boot/dts/qcom/ipq5018-wta301.dts` 的
`/chosen/bootargs-append`，与 S7 逐字一致）

⇒ 一旦序号漂移 1，内核会去挂 `kernel` 分区当 rootfs，**直接起不来**。

要让它变成安全改动，得同时：
1. 改 bootargs 用别的寻址方式（label / UBI 卷名），
2. 或者保证分区**追加在末尾**且实测序号不变，
3. 并且实测一次掉电中断后的恢复。

这三件事每一件都要刷一轮 flash（~10 分钟 + 需要 TTL 在场）。
按 AGENTS.md §5.6「任何会切断 TTL / 破坏回退路径的操作，先停下来问用户」——
这个改动**收益不足以承担风险**，明确不做。

---

## 四、现有 TTL 流程已经完全够用（已实测 20/20）

| 项 | 状态 |
|---|---|
| 一键刷写脚本 | `work/scratch/uboot_flash.py`（断电→抓 u-boot→立即 TFTP→逐区真校验） |
| 每区三列校验 | 本地 crc32 = RAM crc32 = NAND 回读 crc32 |
| guard 白名单 | 20 条命令全部过 `work/out-final/guard.py` |
| 回退资产 | `work/backup/FROZEN-S7-20261105/`；B 槽 mtd10/mtd11 全程未动 |
| P7/P8 实测 | 全部通过 |

升级一次需要：串口线 + 断电 + 约 5 分钟。对家用路由器（一年升级几次）完全可接受。

---

## 五、如果将来真要做 in-Linux 升级，正确的前置条件

按顺序做完这些再来（缺一不可）：

1. **先把 rootfs 改成按 label 或 UBI 卷名挂载**，让 `root=` 不再依赖 mtd 序号。
   参考：本板 overlay 已经用 `ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data`，
   这条路是通的，可以照搬思路。
2. 在 DTS 追加 `tphdr` 分区，并**实测 `cat /proc/mtd` 序号未变**（或已按新序号改 bootargs）。
3. 在 Linux 侧实现 tphdr 重建（md5 四字段），并**与离线 `mk_op_pack.py` 逐字节比对**
   （同一个 tphdr 输入要产出同 32 字节 md5，做不到就不许上线）。
4. 加掉电中断测试：在写 kernel 之后、写 tphdr 之前强行断电，
   验证 B 槽能自动接管且能 TTL 救回。

---

## 六、给家里人的操作卡片（升级怎么做）

```
1. 断电（智能插座 off）
2. 上电，串口抓 u-boot 提示符 IPQ5018#（脚本自动）
3. 跑：python work/scratch/uboot_flash.py --cmds <flash_cmds.txt> --fp <FINGERPRINT.json>
4. 看最后一行 [5] 结论: N/N 通过
5. 断电冷启动，跑 work/scratch/sweep12.py 复核 12 模块
```

出问题：断电 → u-boot 里让 `boot_flag`(mtd13) 指向 B 槽 → 用
`work/backup/FROZEN-S7-20261105/` 刷回 S7。
