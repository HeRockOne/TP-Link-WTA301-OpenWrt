# P11 — overlay 持久化修复：真机验证通过

日期：2026-11-05
产物：`work/images/v25.12.6-P11/`
证据：`work/evidence/p11-flash.log`（刷写 20/20）· `p11-boot1.log` ·
`p11-boot2.log` · `p11-after-factoryreset.log`

---

## 0. 本次唯一变量

```
fstools 补丁：mount_root done() + factoryreset main() 认 fstools_overlay_name
```

| 区 | P10 | P11 | 说明 |
|---|---|---|---|
| kernel | `4131c6d0` | `4131c6d0` | **未变** |
| rootfs | `04a0be1c` | `1e934886` | 含补丁后的 fstools |
| tphdr | `f487269c` | `a8f176ea` | `+0xa0` 跟随 rootfs |
| ubi overlay | `149f0a5d` | `036aadc6` | 空 UBIFS 不可字节复现（已知项） |

---

## 1. 刷写：20/20 真校验通过

| 区 | crc32 | u-boot 回读 |
|---|---|---|
| kernel | `4131c6d0` | `==> 4131c6d0` ✅ |
| rootfs | `1e934886` | `==> 1e934886` ✅ |
| ubi overlay | `036aadc6` | `==> 036aadc6` ✅ |
| tphdr | `a8f176ea` | `==> a8f176ea` ✅ |

方式：`work/scratch/coldflash.py --reboot`（Linux 里敲 reboot → 洪泛单字节 `s`
→ 见 `IPQ5018#` 停发 → 逐区写 + `nand read` 到旁址再 crc32）。全程未用插座。

> 注意：本板 u-boot 的 `bootcmd=bootipq`，而 `bootipq` 读的是 `0x800000`
> （B 槽头），不是我们刷的 A 槽。启动必须走
> `nand read 0x44000000 0x4880000 0x480000` + `bootm 0x44000000`。
> `boot` 命令在 this u-boot 里不存在，`run bootcmd` 会走错槽。

---

## 2. 两次（实为三次）重启协议 —— 全部通过

判据不能用"单次冷启动"，必须「写 → 重启 → 还在」。

### boot #1（刷完首启，overlay 为空 ⇒ 格式化一次，正常）

```
[   13.045453] mount_root: overlay filesystem has not been fully initialized yet
[   13.054668] mount_root: switching to ubifs overlay
```

启动后写入标记：

```
echo P11-MARK-AAA > /root/persist.txt
mkdir -p /etc/persist && echo hello > /etc/persist/a.conf
uci set system.@system[0].hostname=wta301-home && uci commit system
```

`/overlay/.fs_state` = **symlink → 2**（READY）。

### boot #2 与 boot #3（`reboot` 两次）

| 判据 | 结果 |
|---|---|
| `cat /root/persist.txt` | `P11-MARK-AAA` ✅（**boot #3 仍在**） |
| `cat /etc/persist/a.conf` | `hello` ✅ |
| 提示符 / `uci get system.@system[0].hostname` | `wta301-home` ✅ |
| `readlink /overlay/.fs_state` | `2` ✅ |
| `dmesg \| grep -c 'not been fully initialized'` | **0** ✅ |
| `ls /overlay/upper/` | `etc lib root run`（P9 只有 `etc lib run`） ✅ |
| `ls /overlay/upper/root/` | `persist.txt`（文件确实落在 overlay upper 层） ✅ |
| `ping -c 2 192.168.1.100` | `0% packet loss` ✅ |
| `iw dev` | `phy0-ap0` OpenWrt-WTA301 / `phy1-ap0` OpenWrt-WTA301-5G ✅ |

---

## 3. 顺带验证：`factoryreset` 现在也能用（同类缺陷已修）

修复前 `factoryreset.c` 同样是字面量 `volume_find("rootfs_data")`，
会直接报 `MTD partition 'rootfs_data' not found` 并退出 —— **重置彻底失效**。

修复后实测：

```
root@wta301-home:~# factoryreset -y
/dev/ubi0_0 is mounted as /overlay, only erasing files
FR_RC=0
```

擦完后的恢复过程也验证了（这是**出厂恢复路径**，家用必须具备）：

| 判据 | 结果 |
|---|---|
| 重启后 `readlink /overlay/.fs_state` | `2` ✅（重新建立） |
| 重启后 `dmesg \| grep -c 'not been fully initialized'` | **1**（被擦后的首次格式化，正确的一次性行为） |
| 再重启一次 | **0** ✅ ⇒ 不再重复格式化 |
| `ping 192.168.1.100` | `0% packet loss` ✅ ⇒ `/etc/config/network` 被擦后由 `90_wta301` 正确重建 |
| `iw dev` | `phy1-ap0` OpenWrt-WTA301-5G ✅ ⇒ Wi-Fi 配置来自 rootfs（P9 固化），不依赖 overlay |

⇒ **「恢复出厂 → 自动恢复可用」这条路径是通的。**

---

## 4. 与 S7 的一致性（不再是"相似补丁"）

编译进 rootfs 的 `sbin/mount_root`：

- 大小 **8155 B，与 S7 的 `mount_root` 完全相同**
- `cmp -l` 逐字节差异 **仅 19 字节**（集中在构建时间戳/版本字符串处）
- 反汇编的指令引用位置完全一致：

```
fstools_overlay_name (0xdc2) refs: 2  ->  0xa20, 0xc40
rootfs_data          (0xdb0) refs: 2  ->  0xa38, 0xc58
```

`lib/libfstools.so` 的 md5 与 P9 相同（`705701a5…`）—— 只改了两个 main 程序，
共享库未动，符合预期。

---

## 4b. 连带修复：SSH host key 不再每次重启都变

P9 及之前 overlay 每次被擦，`/etc/dropbear/dropbear_*_host_key` 每启动重新生成，
客户端 SSH 会一直报 `HOST KEY CHANGED`（家用时很烦，也是"被中间人"的假警报）。

P11 实测 host key 已落在 overlay upper 层，随 `.fs_state -> 2` 一起持久：

```
-rw-------  1 root root  83 Oct 17 21:45 dropbear_ed25519_host_key
-rw-------  1 root root 805 Oct 17 21:45 dropbear_rsa_host_key
md5  df9e521f489c40d90e3e4a0f1642cf03  (ed25519)
     080552379b8182be54cb81125c993374  (rsa)

/overlay/upper/etc/dropbear/ 里同时存在这两个文件  ⇒ 已持久化
```

（下次重启可复核上面两个 md5 是否不变。）

## 5. 判据坑（两条，已记 lesson）

1. **`.fs_state` 是 symlink，不是普通文件。** `fs_state_set()` 用
   `symlink("2", path)`。`cat /overlay/.fs_state` **永远**报 No such file。
   正确判据是 `ls -l` 或 `readlink`。我在 P9 阶段用 `cat` 判定"文件不存在"，
   结论恰好对（P9 确实坏），但判据本身是错的，必须纠正。
2. **单次冷启动永远看不出这个 bug。** 新格式化的空 overlay 当然能写。
   判据必须是「写 → 重启 → 还在」。

---

## 6. 家用判定

| 项 | 状态 |
|---|---|
| 系统 25.12.6 / 内核 6.12.112 | ✅ |
| 有线连通（1Gbps，lan1-5 进 br-lan） | ✅ |
| Wi-Fi 双射频默认启用（ch6 / ch36-80MHz） | ✅ |
| 配置/文件跨重启持久 | ✅ **本轮修好** |
| 恢复出厂可用 + 恢复后自动可用 | ✅ **本轮修好** |
| 固件可复现构建 | ✅（kernel/rootfs/tphdr 逐字节相同） |
| 回退到 S7 | ✅ 资产完整，B 槽与一级 u-boot 未动 |

**尚未覆盖（非阻塞，但家用前应确认）**：

1. 默认 Wi-Fi 密码仍是 S7 的 `123456789` —— **首次登录必须改**
2. 物理 reset / wps 按键（gpio20 / gpio17）需现场按一次
3. 内存 `MemAvailable` 只有 40 分钟数据，建议再跑长时 soak
4. 时区/NTP 仍为 UTC + openwrt.pool（S7 是 CST-8 + 阿里云），未改
