# M12 Wi-Fi 固件 / BDF / caldata

**结论：三个固件资产全部 100% 二进制复用，零改动。
board-2.bin 里的 BDF 数据 = ART 提取的 caldata，不是原厂通用 bdwlan。**

---

## 1. 先把三份 BDF 的关系钉死

### 1.1 来源与实测 md5

| 来源 | 路径 | 大小 | md5 |
|---|---|---|---|
| 原厂 rootfs（2.4G 通用 BDF） | `/lib/firmware/IPQ5018/bdwlan.b10` | 131,072 | `51ae6326852a85ccb948764f17915353` |
| 原厂 rootfs（5G 通用 BDF） | `/lib/firmware/qcn6122/bdwlan.b50` | 131,072 | `2cff4ad956de6ce61c9347d29df14fa6` |
| ART 解压后全量（`mtd2` 是 gzip+tar） | `work/scratch/virtual_art.bin` | **524,288** | `dad7c3afc009a6c27b800b37a560ce36` |
| ART `+0x1000` len `0x20000`（本机 2.4G cal） | —— | 131,072 | **`f15ca65305465749986f19662aaefb19`** |
| ART `+0x26800` len `0x20000`（本机 5G cal） | —— | 131,072 | **`c681908f261826dda8ff6c90e1ecbba5`** |

**本地复算验证（已跑通，两次独立确认）**：
```
virtual_art.bin  size=524288  md5=dad7c3afc009a6c27b800b37a560ce36
  2.4G off=0x1000  len=0x20000  md5=f15ca65305465749986f19662aaefb19  == 期望 OK
  5G   off=0x26800 len=0x20000  md5=c681908f261826dda8ff6c90e1ecbba5  == 期望 OK
```
且这两个 md5 与 S7 rootfs 里 `/lib/firmware/ath11k/{IPQ5018,QCN6122}/hw1.0/caldata.bin`
**逐字节相同**。

### 1.2 「通用 BDF」与「本机 cal」的差异

| 射频 | 通用 BDF | 本机 cal | 差异字节数 | 差异位置（前几个） |
|---|---|---|---|---|
| 2.4G | `51ae6326…` | `f15ca653…` | **25** | `0xa`, `0xb`, `0x1a02`, `0x1a04–0x1a06`, `0x1a0b–0x1a0e`, … |
| 5G | `2cff4ad9…` | `c681908f…` | **79** | `0xa`, `0x272c–0x2733`, … |

`0xa`/`0xb` 是 BDF 头部版本/长度字段，其余集中在 `0x1a00+` / `0x2700+` 的**功率与校准区**。
⇒ 印证：`bdwlan` = 出厂通用模板，ART 里的 = 「通用模板 + 本机逐台校准微调」。
⇒ **必须用本机 cal**，不能用通用 BDF（否则发射功率是别人的）。

### 1.3 ★ S7 的 board-2.bin 里装的是 cal，不是通用 BDF

解析 S7 实际在用的两个文件（工具 `tools/parse_board2.py`）：

| 文件 | 大小 | md5 | 内嵌 BDF 数据 md5 | 等于哪个？ |
|---|---|---|---|---|
| `board2-wta301-ipq5018-2g.bin` | 131,180 | `78f5b21b2cd1dee8fb6155e1f74a1073` | `f15ca65305465749986f19662aaefb19` | **本机 2.4G cal** |
| `board2-wta301-qcn6122-5g.bin` | 131,180 | `e4904f1326df5edfd7842b319e0828da` | `c681908f261826dda8ff6c90e1ecbba5` | **本机 5G cal** |

与 S7 rootfs 树 `/root/lp/tree/lib/firmware/ath11k/…/board-2.bin` 的 md5 **完全一致**：
```
78f5b21b2cd1dee8fb6155e1f74a1073  IPQ5018/hw1.0/board-2.bin
e4904f1326df5edfd7842b319e0828da  QCN6122/hw1.0/board-2.bin
```
且本地资产 `work/op-build/assets/bdf/board2-wta301-*.bin` 就是这两个文件（同一份）。

**为什么 board-2.bin 里也放 cal**：ath11k 会分别请求两个文件 ——
board data（`board-2.bin`，含 variant 名匹配）和 caldata（`caldata.bin`）。
本机 cal 比通用 BDF 多了 25/79 字节校准 ⇒ 直接拿 cal 当 board data 用，两处内容一致，
不会出现「board 说一套、cal 说另一套」。S7 已实证可用。

---

## 2. board-2.bin 容器格式（实测反推，逐字段对上）

```
0x00  17 B   "QCA-ATH11K-BOARD\0"                ← magic 含 NUL，17 字节
      pad→4B  （用 'm' 填充，不是 0x00）
0x14  u32    0
0x18  u32    131152  = 文件总长 − 0x1c           （小端）
0x1c  u32    0
0x20  u32    61      name_len                    （小端）
0x24  61 B   "bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=TP-Link-WTA301"
0x61  pad→4B（"mmm"，3 字节）
0x64  u32    1       count
0x68  u32    131072  size
0x6c  …      BDF/cal 数据（131072 B）
```

校验：`0x6c + 131072 = 131180` = 文件总长，**尾部 0 字节剩余** ✅

### 2.1 两个易错点

1. **magic 是 17 字节**（`ATH11K_BOARD_MAGIC_LEN = 17`，含结尾 NUL），不是 16。
   早期版本 `b"QCA-ATH11K-BOARD\x00"` 写成 18 字节会导致全部错位。
2. **所有 u32 是小端**。读 `0x18` 时按大端会得到 `0x50000200`（无意义），
   按小端才是 `0x00020050 = 131152`。

### 2.2 variant 名必须与 DTS 完全一致

DTS：`qcom,ath11k-calibration-variant = "TP-Link-WTA301"`
board-2.bin：`…,variant=TP-Link-WTA301`
⇒ 61 字节的 name 串必须**逐字节**对齐（含大小写与连字符）。
上游 `ath11k-firmware-ipq5018` 包自带的 board-2.bin 里只有
`variant=TP-Link-Archer-AX55-v1` ⇒ **对不上，这就是当年 `-12` 的根因**
（详见 `work/docs/WIFI-BDF-CALDATA.md` §3.1）。

---

## 3. 固件本体

### 3.1 包里有什么、没什么

`ath11k-firmware-ipq5018-qcn6122` `V:2024.10.14~15f05012-r2`（commit `15f050122da5…`，
来源 `https://git.codelinaro.org/clo/ath-firmware/ath11k-firmware.git`）：

**提供**（38 个文件）：
- `IPQ5018/hw1.0/`：`Notice.txt` · `m3_fw.b00,b01,b02,flist,mdt` · `q6_fw.b00–b26`（缺 b06/b12/b19/b24，固件本身就没有）· `q6_fw.flist` · `q6_fw.mdt`
- `QCN6122/hw1.0/`：`Notice.txt` · `m3_fw.b00,b01,b02,flist,mdt`

**不提供**：`board-2.bin` · `caldata.bin`
⇒ 这两个是**我们自己打进 rootfs** 的（S7 的构建脚本负责）。

### 3.2 q6/m3 固件的版本号（S7 实测）

```
fw_version     0x270206d0
fw_build_timestamp 2022-08-04 13:28
fw_build_id    WLAN.HK.2.7.0.1-01744-QCAHKSWPL_SILICONZ-1
```

这份固件是 **Qualcomm 2022-08-04 发布**，`ath11k-firmware` 包自 2024.10 后未再更新 IPQ5018 部分。
⇒ 25.12.6 若用同名同版本包，**固件二进制完全相同**。

### 3.3 为什么可以 100% 复用

固件（`.mdt` + `.bXX`）通过 **QMI** 与驱动通信。QMI 接口是 Qualcomm 的稳定 ABI，
不随 Linux 内核版本或 mac80211 backports 版本变化。
⇒ 25.12.6 的 backports-6.18.55 的 ath11k 用同一份固件，与 6.18.55 内核 + backports-7.2 无异。

**唯一的例外**：若 ath11k 改了固件加载的 QMI 消息格式（`ath11k_qmi.c` 里的
`qmi_wlanfw_*_req_msg_v01` 结构），固件需匹配。而 25.12.6 与 S7 用的是
**同一代的 patch 集（19 个同名补丁）** ⇒ QMI 结构未变。

---

## 4. MAC 地址来源（与 BDF 无关，但同属本模块）

**原厂 ART 里没有 MAC**（解压后搜不到本机 MAC）。
真 MAC 在 `factory_info`（mtd1，offset 0x400000）的 **`M1CT` TLV 容器**：

```
0x00  "M1CT"
0x04  20 字节头
0x18  TLV 起始：type(be16) len(be16) value
      type=0 的 6 字节 value = MAC
      ⇒ 文件偏移 0x1c
```

⇒ `/etc/board.d/` 或 DTS 侧用 `mtd_get_mac_binary factory_info 0x1c`。
2.4G = MAC+2，5G = MAC+3（沿用同族参考设计）。
（AX55 的 `mtd_get_mac_binary 0:art 12` 在本板**无效**。）

> 待 P4 上电核对：`cat /sys/class/ieee80211/phy*/macaddress` 与机壳标签是否一致。

---

## 5. 迁移动作清单（M12）

| # | 文件 | 动作 | 依据 |
|---|---|---|---|
| 1 | `board2-wta301-ipq5018-2g.bin` → `/lib/firmware/ath11k/IPQ5018/hw1.0/board-2.bin` | **字节直抄**，md5 必须 = `78f5b21b2cd1dee8fb6155e1f74a1073` | §1.3 |
| 2 | `board2-wta301-qcn6122-5g.bin` → `/lib/firmware/ath11k/QCN6122/hw1.0/board-2.bin` | **字节直抄**，md5 必须 = `e4904f1326df5edfd7842b319e0828da` | §1.3 |
| 3 | `caldata.bin` ×2 | **字节直抄**，md5 `f15ca653…` / `c681908f…`（内容 = ART 对应段） | §1.1 |
| 4 | `q6_fw.*` / `m3_fw.*` | 用 `ath11k-firmware-ipq5018-qcn6122` 包（或直接拷 S7 rootfs 的同路径） | §3 |
| 5 | 不用 `ipq-wifi-*` 子包 | 本板不在上游，`ipq-wifi-tplink_archer-ax55-v1` 的 variant 名对不上 | §2.2 |
| 6 | **不修改** board-2.bin（不要「重新生成干净版」把 `m` 填充改成 `0`） | 单一变量：S7 这份已实证可启动 | §2 |

> 注：S7 的 board-2.bin 填充字节是 `'m'`（0x6d）而不是 `0x00`。
> 不美观，但 ath11k 跳过 pad 区，S7 真机双射频正常 ⇒ **不动它**。

---

## 6. P4/P5 必测（M12 部分）

| # | 命令 | 通过判据 |
|---|---|---|
| 1 | `md5sum /lib/firmware/ath11k/*/hw1.0/board-2.bin` | 与 §1.3 两个值一致 |
| 2 | `md5sum /lib/firmware/ath11k/*/hw1.0/caldata.bin` | `f15ca653…` / `c681908f…` |
| 3 | `dmesg \| grep "failed to fetch board data"` | **0 行** |
| 4 | `dmesg \| grep "failed to load board data file"` | **0 行** |
| 5 | `dmesg \| grep fw_build_id` | `WLAN.HK.2.7.0.1-01744-QCAHKSWPL_SILICONZ-1` |
| 6 | `cat /sys/class/ieee80211/phy*/macaddress` | 非 `00:00:00:00:00:00`，且两射频不同（差 1） |
| 7 | `iw phy \| grep -c "Band [0-9]"` | 每个 phy 至少 2 个 band |

---

## 7. 与 M04 的交叉点

`M04-WIFI-DRIVER.md` §4 记录了「S7 的 ath11k.ko 里没有 924 multipd 补丁」。
本模块的结论不受影响：**BDF/cal 的加载路径与 multipd 无关**（前者是文件读取 + QMI BDF 下载消息，
后者是 QMI 服务实例号偏移）。但若 25.12.6 上 5G 起不来，两个模块都要查：

1. 先查 M12 的判据 3/4（BDF 找到了吗）
2. 再查 M04 的判据 2/3（userpd / remoteproc 起来了吗）
