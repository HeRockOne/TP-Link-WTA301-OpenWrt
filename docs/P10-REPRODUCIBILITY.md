# P10 — 构建可复现性验证 + 出厂包自校验修复

日期：2026-11-05
包：`work/images/v25.12.6-P10/`（与 P9 同源重建）
日志：`/root/p10.log`（`make world` EXIT=0）、`/root/mrel2.log`

---

## 1. 本次目的（不是新增功能）

**从同一份源码重跑 `deliver/apply-to-2512.sh` + `make -j8 world`，验证产物是否可复现。**

结果：**kernel / rootfs / tphdr 三项逐字节相同**。

| 区 | P9（板子上正在跑的） | P10（同源重建） | 判定 |
|---|---|---|---|
| kernel | `4131c6d0` / `842d204e…` | `4131c6d0` / `842d204e…` | **完全相同** ✅ |
| rootfs | `04a0be1c` / `f0525a4f…` | `04a0be1c` / `f0525a4f…` | **完全相同** ✅ |
| tphdr | `f487269c` / `376053b7…` | `f487269c` / `376053b7…` | **完全相同**（`+0xa0` 都是 `d85f1938…`） ✅ |
| ubi overlay | `66e210d0` | **`149f0a5d`** | 字节不同，**结构相同**（见 §2） |

⇒ **板子上的 P9 就是 P10**，不需要重刷。可复现性成立，说明出包链路没有隐藏的随机输入。

---

## 2. 为什么 UBI 镜像字节不可复现（已知、无害）

`op_..._wta301data.img` 是**空** UBIFS 卷经 `mkfs.ubifs` + `ubinize` 打包。
两者都会把**当前时间戳**写进 superblock/root inode，而 `SOURCE_DATE_EPOCH`
在本机 host 工具（非 OpenWrt 编译产物）上不生效 ⇒ 每次重建字节都不同。

**判据只能看结构**，`verify_pack.py` 就是这么做的，两个包都 PASS：

```
ubi_rootfs_data3_wta301data.img  1966080 B  15 PEB
vtable: 卷名 'wta301data'  reserved_pebs 13  alignment 1
        data_pad 0  vol_type 1  flags 0x01  crc ✓
```

（`flags & 0x01` = autoresize ⇒ 首启自动长满整个 mtd12）

**功能等价**：overlay 首启本来就要重新格式化，镜像里的空 inode 不会被沿用。

---

## 3. 修复：`verify_pack.py` 的过时判据（假 FAIL）

旧版第 162 行硬编码：

```python
if name != 'rootfs_data':
    bad('卷名必须是 rootfs_data（25.12.6 的 fstools 写死只认这个名字）')
```

**这条规则已经被真机推翻**（P9 之前就推翻，lesson `n1uvh1l`）：
25.12.6 的 fstools `mount_root.c:42` 会

```c
get_var_from_file("/proc/cmdline", "fstools_overlay_name", dataname)
...
volume_find(dataname)
```

即**卷名可配置**，只要 bootargs 里的 `fstools_overlay_name=` 与卷名一致。
我们正是用 `wta301data` + `fstools_overlay_name=wta301data`，P6~P9 真机全部验证通过。

### 修法

`check_ubi()` 增加 `allow_name` 参数，由新增的 `_cmdline_overlay_name(dir)`
从包内 `FINGERPRINT.json` 的 `bootargs` 解析 `fstools_overlay_name=` 的值传入：

```python
if name == 'rootfs_data':
    info("卷名 'rootfs_data' —— fstools 默认认的名字")
elif name == allow_name:
    info("卷名 %r —— 与 bootargs 的 fstools_overlay_name 一致" % name)
else:
    bad("卷名 %r 既不等于 'rootfs_data'，也不等于 bootargs 里的 "
        "fstools_overlay_name（%r）⇒ 首启不会挂这个卷做 overlay")
```

修改后两个包都 **PASS**。修改前，**任何**合法包都会被判 FAIL —— 这是危险方向
（假 FAIL 会诱导人去改本来正确的卷名，改回 `rootfs_data` 反而让 P6~P9 的
真机验证失效）。

---

## 4. 修复：出包元数据写死成 P3

`/root/mrel.sh:114` 原先把 `--version P3-2512 --stage P3 --purpose "…首次真机验证"`
写死，导致 P10 的 `FINGERPRINT.json` 张口就说自己是 P3。改为可覆盖：

```sh
--version "${VER:-25.12.6-r33311}" --stage "${STAGE:-P10}" \
--purpose "${PURPOSE:-…家用稳定版…}"
```

---

## 5. 结论

- 构建链可复现（三项逐字节相同），无隐藏随机源。
- UBI 镜像不可字节复现属**已解释的已知项**，判据用结构。
- 两个工具问题（`verify_pack.py` 假 FAIL、`mrel.sh` 元数据写死）已修。
- **板子保持 P9 不动**，它就是 P10 的等价物。
