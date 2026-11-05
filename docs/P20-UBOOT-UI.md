# P20 — 修复官网固件识别 + 网页界面重做 + 槽位可见化

> 状态：**代码已改、已编译、产物已交付；尚未上板验证**
> 产物：`u-boot.bin` 551,480 B · md5 `ce9bf381e1f00b8147df2abdb228f76f`
> 槽镜像：`uboot_p20_slot.bin` 262,144 B · md5 `b71d9b2f172123827f3ffc5c861491f7` · crc32 `0x88848A85`

---

## 1. `factory_no_fit` —— 字节序写反（本次唯一的 bug 修复）

用户实测网页刷 TP-Link 官网 `fw_202.bin` 报：

```json
{"status":"fail","info":{"type":"invalid_tplink_firmware","reason":"factory_no_fit"}}
```

### 根因

`board/qca/arm/common/tplink_tpimg.c` 里这段：

```c
if (be32(fit) != 0xEDFE0DD0)     /* ← 错 */
```

`be32()` 是按大端拼的，返回 `0xD00DFEED`；而 `0xEDFE0DD0` 是 `d0 0d fe ed`
这四个字节按**小端**读出来的值。两个值不相等，于是任何官网包里合法的
FIT/DTB 都被判成「不是 FIT」。

### 证据

```
PC 侧（python）:
  fw_202.bin @0x60200 = d0 0d fe ed
  struct.unpack('>I', ...) = 0xD00DFEED     ← be32() 的口径
  struct.unpack('<I', ...) = 0xEDFE0DD0     ← 原代码的口径
```

`fw_dec.c:74` 里 `#define HEADER_MAGIC_FIT 0xEDFE0DD0` **是对的**——那里配的是
`*(u32 *)p`（原生小端读）。两处口径不同，`tplink_tpimg.c` 抄错了。

### 修法

```c
/* DTB/FIT magic 的大端值是 0xD00DFEED（字节 d0 0d fe ed）。 */
if (be32(fit) != 0xD00DFEED) { ... }
```

### 顺带复核的算术（全部通过）

`fw_202.bin` 17,302,016 B：

| 检查项 | 结果 |
|---|---|
| FIT 长度 `0x2859F8` ≤ kernel 槽 `0x400000` | ✓ |
| FIT → rootfs 间隙 1,549,832 B 全 `0xFF` | ✓ |
| rootfs @`0x460200` magic = `hsqs` | ✓ |
| `bytes_used 0xBAE8A5` → 对齐 `0xBC0000` ≤ A 槽 `0xC00000` | ✓ |
| `rootfs_off + vlen = 0x1020200` ≤ 文件 `0x1080200` | ✓ |
| 尾部 71,515 B 全 `0xFF` | ✓ |

结论：修掉字节序之后这个包能完整写进 A 槽。

---

## 2. 网页界面重做（`failsafe/fsdata/index.html`）

33,550 B → gzip 10,266 B（旧 7,324 B）。

### 布局

左右两栏，`<860px` 自动堆叠。

- **左栏（常驻）**：系统信息（模型/版本/IP）· **两个槽位的实时状态** · 导航
- **右栏（随导航切换）**：操作面板

### 导航

固件升级 ｜ U-Boot ｜ 环境变量 ｜ 系统信息·调试 ｜ 重启设备

原来的折叠块全部取消——折叠需要点两次才能看到内容，面板本来就不长。

### 槽位显示

每个槽一行：`image_1 / image_2` + md5 前 8 位 + 完好状态徽标 + 「运行中」标记。
数据来自新接口 `GET /sysinfo/tplink`。

### U-Boot 页新增「写入目标」

| 选项 | 含义 |
|---|---|
| 两槽都写（默认，推荐） | 双槽冗余保持；一级先验 image_1 会启动新的 |
| 只写 image_1 | 立即生效，image_2 保留旧的做退路 |
| 只写 image_2 | 备槽更新，当前不生效（一级先验 image_1 通过就用它） |

前端通过 multipart 字段 `slot`（`0`/`1`/`2`）传给后端。

---

## 3. 后端改动

### 3.1 新接口 `GET /sysinfo/tplink`（新文件 `failsafe/modules/tplinkinfo.c`）

```json
{
  "status": "success",
  "uboot_run": { "slot": "image_2", "assumed": true },
  "boot_flag": { "ok": true, "raw": 2 },
  "slots": [
    { "name":"image_1", "active":true,  "hdr_ok":true, "md5_match":true, "decode_ok":true, "md5_ok":"b71d9b2f…" },
    { "name":"image_2", "active":false, "hdr_ok":true, "md5_match":true, "decode_ok":true, "md5_ok":"b71d9b2f…" }
  ],
  "firmware_slot": { "name": "image_2", "label": "A 槽 · kernel + rootfs" },
  "uboot_target": 0
}
```

判定口径与串口 `tplcheck` **共用同一份代码**（`status_one_slot()`），
所以页面说「完好」和串口打 `OK` 是同一件事，不会两处结论打架。

区别只有一点：`tpimg_selfcheck()` 往串口打，`tpimg_get_status()` 只填结构体
（`include/failsafe/tplink_tpimg.h` 里的 `struct tpimg_status`）。

耗时 1~2 秒（读 2×128K 头 + 2×256K 槽 + 两次 LZMA 解码），所以只在页面加载和
点「重新检测槽位」时调，不做轮询。

`uboot_run.assumed` 恒为 `true`：镜像本身没有槽号，只能靠 boot_flag
（`0x4000000`，魔数 `0x55aa4246` + 槽号）推断，不是本进程能自证的身份。

### 3.2 `slot` 参数贯通

| 文件 | 改动 |
|---|---|
| `failsafe/modules/upgrade.c` | `/upload` 阶段解析 multipart 的 `slot` 字段，校验只有单个字符 `1`/`2` 才采用 |
| `include/failsafe/tplink_tpimg.h` | 新增 `TPIMG_UBOOT_TARGET_*` 与 `extern int tpimg_uboot_target` |
| `board/qca/arm/common/tplink_tpimg.c` | `tpimg_uboot_write()` 按 `tpimg_uboot_target` 决定写哪几个槽 |
| 同上 `do_tpluboot()` | 命令行 `tpluboot` **强制**设为两槽都写，不受网页选项影响 |

为什么在 `/upload` 阶段就记下来：那里是真正解析过 multipart 的地方，
`/result` 阶段只发了个空 body（前端 `doFlash` 传的 `slot=N` 字符串），
再解析一次容易出偏差。

### 3.3 `FAILSAFE_IDLE_MS_NOCLIENT` 30 s → 180 s

`failsafe/failsafe.c:44`。

原值 30 秒太短：按住 reset 进网页后，用户还要插网线、开浏览器、等页面加载，
经常刚打开就被超时踢进 Linux（表现是「页面转圈然后连接中断」）。

连上过就不计时（`has_client` 置位后永不再超时），所以变长只是给「还没连上」
的人留时间，不影响刷机过程本身。

---

## 4. 两条硬约束（用户提醒后量化）

| 约束 | 上限 | P20 产物 | 余量 |
|---|---|---|---|
| 压缩后进槽 `TPIMG_UBOOT_SLOT_LEN` | 262,144 B | 222,370 B | 39,774 B (15%) |
| 一级解压缓冲 `TPIMG_UBOOT_DEC_CAP` | 655,360 B | 551,480 B | 103,880 B (16%) |

先撞的是**解压后 655,360 B**（`include/failsafe/tplink_tpimg.h:144-145`）。
新 UI 的 gzip 比旧版多 2,942 B，占余量 7%，安全。

以后再加功能要先看这两个数字，尤其是解压后那个。

---

## 5. 文件清单

`patches/uboot/p20/`：

| 文件 | 对应源码路径 |
|---|---|
| `tplink_tpimg.c` | `board/qca/arm/common/tplink_tpimg.c` |
| `tplink_tpimg.h` | `include/failsafe/tplink_tpimg.h` |
| `failsafe.c` | `failsafe/failsafe.c` |
| `index.html` | `failsafe/fsdata/index.html` |
| `modules/tplinkinfo.c` | 新文件 `failsafe/modules/tplinkinfo.c` |
| `modules/upgrade.c` | `failsafe/modules/upgrade.c` |
| `modules/modules.h` | `failsafe/modules/modules.h` |
| `modules/Makefile` | `failsafe/modules/Makefile` |

---

## 6. 上板验证清单（**未做**）

1. 刷 `uboot_p20_slot.bin`（两槽都写）→ 重启 → banner 应是 `2026-11-06 02:46` 左右
2. 左栏两个槽 md5 都显示 `b71d9b2f`
3. U-Boot 页选「只写 image_1」→ 传一次 → 串口应打 `u-boot target slot = 1` 且只写 0x700000
4. 网页刷 `fw_202.bin` —— **这是 P18 新增的路径，从来没跑通过**，重点验证
5. 网页刷 `op_wta301_firmware_web.bin`
6. 验证 180 秒超时：进网页后放着不动，3 分钟内页面不该断

---

## 7. 已知遗留

- 默认 WiFi 密码仍是 S7 时代的 `123456789`
- `/etc/rc.button/reset` 阈值 5 s（原厂惯例 10 s）
- 未开 WAN 口
- mtd8 那 22 MB 未利用

---

## 11. P20c：`/result` 必须发空 body（浏览器「写入失败」的真正根因）

### 症状
- 「上传并校验」通过（`262144 B · LZMA`），「写入 Flash」只显示「写入失败」，无任何原因。
- 串口里 `/result` 之后**一行日志都没有**（连 `httpd_recv_payload` 都没有）。

### 决定性证据
用 python 重放两个请求（`tools/replay_uboot_write.py`）：

| 请求 | 结果 |
|---|---|
| `POST /upload`（multipart） | `200` · `{"status":"success","info":{...md5:"59163039..."}}` |
| `POST /result`（body=`"slot=0"`，即浏览器发的） | **`400 text/html` · 11 字节 · `Bad Request`** |

串口实录（`work/evidence/p20b-write.log`）：
```
httpd_recv_hdr: POST /result
httpd_recv_hdr: Content-Length: 6 Bytes
                       ← 到此为止，没有 payload、没有 handler 日志
```

### 根因（`net/httpd.c:549-552`）
```c
ct_ptr = strstr(fields_ptr, content_type_str);
if (ct_ptr) {
        b_ptr = strstr(ct_ptr, boundary_str);
        /* only accept multipart/form-data */
        if (!b_ptr)
                goto bad_request;      /* → 400 */
}
```
- 只要请求头里有 `Content-Type` 却**没有 `boundary=`**，httpd 在**头解析阶段**就 400，
  handler 根本不会被执行。
- 浏览器对**字符串** body 会自动加 `Content-Type: text/plain;charset=UTF-8`
  ⇒ 正好落进这个分支。
- **空 body 的 POST 不带 `Content-Type` 头** ⇒ 跳过该分支 ⇒ 正常进入 `result_handler`。
  历史上所有成功记录（`curl -X POST /result` 不带 body）走的都是这条路。

### 修法
`failsafe/fsdata/index.html` 的 `doFlash()`：
- 去掉 `body` 参数与 `x.send(body||null)`，改为 `x.send()`。
- 写入目标（slot 0/1/2）**在 `/upload` 阶段就交给板子**并存进 `tpimg_uboot_target`
  （`modules/upgrade.c` 的 `HTTP_CB_RESPONDING` 分支），`/result` 不需要任何参数。
- 另外补上：服务端返回非 JSON 时，把 `HTTP 状态 + 原文` 显示出来，
  不再只显示「写入失败」（就是这个坑让我以为 `result_handler` 没设 `response->data`）。

> 更正上一版文档/note 里的错误推断：`result_handler` 在失败时**是**会返回 JSON 的
> （`failsafe_write_image` 失败时设 `response->data = resp`）。这次的 400 发生在
> 更早的 HTTP 头解析层，和 handler 无关。

### 验证（不写 flash，可安全复跑）
`tools/verify_result_fix.py`：`/upload` 一个 1 KB 垃圾（`tpimg_uboot_validate` 必拒），
再发**空 body** 的 `/result`：
```
/upload  → 200 {"status":"fail","info":{"type":"wrong_file_type",...}}
/result  → 200 {"status":"fail","info":{"type":"wrong_file_type",...}}   ← 不再是 400
判定: PASS（且 flash 未写入 —— wrong_fw_type 在动 flash 之前返回）
```

### 实刷记录（P20c）
```
POST /upload  → success  md5 c3a6a2c1db4147f43bca2ab541924f16
POST /result  → 200 {"status":"success","info":{"reboot":false}}
tplcheck      → image_2 0x4700000 OK / image_1 0x700000 OK, 均 decodes to 0x86e38 (=552504 B)
GET /sysinfo/tplink → 合法 JSON, 两槽 decode_ok=true, md5 c3a6a2c1..., boot_flag raw=2
```
