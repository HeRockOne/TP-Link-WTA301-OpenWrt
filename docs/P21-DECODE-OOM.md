# P21 · 页面「解压失败」的真实原因：堆不够

> 症状：u-boot failsafe 页面左栏 image_1 显示「解压失败」、image_2 显示「完好」，
> 但两槽 md5 完全一样（同一份镜像）。同一时刻串口 `tplcheck` 两槽都 OK。
>
> 结论：**不是镜像坏，是 malloc 池不够**。已从根上修（池 1012 KB → 2.5 MB），
> 并把「内存不足」和「解压失败」在 UI 上分开。

---

## 1. 三个独立证据

### 1.1 单请求正常，并发就坏（决定性）

`tools/diag_conc2.py`，6 线程同时打 `GET /sysinfo/tplink`：

```
0 [image_1=False, image_2=True]     ← 第 1 槽失败、第 2 槽成功
1 [False, False]
2 [False, False]
3 [False, False]
4 [True, True]
5 [True, True]

成功 2/6
```

**「第 1 个槽失败、第 2 个槽成功，而两槽 md5 相同」是池不够的指纹**：
`slot[0]` 的 640 KB 解码缓冲要向池顶扩展，失败；`slot[1]` 复用了刚 `free`
的同一块，反而成功。

单请求时 6/6 全好。浏览器一开页面就是多连接并发 —— 所以必现。

### 1.2 池的真实大小（实测，不是静态推算）

`md` 板上符号：

```
499be65c: 49900000 00000000 49680000
          ^end     ^brk     ^start
```
（P21b 修复后；修复前 `start = 0x49803000`）

```
池 = 0x49900000 - 0x49803000 = 0xFD000 = 1,036,288 B = 1012 KB
```

**注意：真实大小 = `CONFIG_SYS_MALLOC_LEN` + `CONFIG_ENV_SIZE`**，
不是 `MALLOC_LEN` 本身。当时 `MALLOC_LEN = 256K + 500K = 756 KB`，
我按 756 KB 算过一版，错了 —— 但也别以为 1012 KB 就够了。

### 1.3 需求

`tplinkinfo` 一次要同时持有：

| 用途 | 大小 |
|---|---|
| 槽镜像读取缓冲 | `0x40000` = 256 KB |
| 解码缓冲 | `0xA0000` = 640 KB |
| **小计** | **896 KB** |
| httpd 每连接的会话/表单开销 | 剩下那点 |

896 KB 对 1012 KB，只剩 116 KB 给 httpd 的并发连接 —— 不够。

`tplcheck` 是单连接、无 httpd 开销，峰值 896 KB 刚好放下 ⇒ **串口说好、
页面说坏**。这就是两边结论不一致的全部原因。

---

## 2. 修改

### 2.1 池 1012 KB → 2.5 MB

`include/configs/ipq5018.h`：

```c
#define CONFIG_SYS_MALLOC_LEN   (CONFIG_ENV_SIZE_MAX + (2048 << 10))   /* 原 500 << 10 */
```

二进制层验证（objdump `initr_malloc`）：

```asm
4990d600: ldr r0, [r9, #0x30]      ; gd->relocaddr
4990d604: mov r1, #2621440         ; 0x280000 = TOTAL_MALLOC_LEN
4990d60c: sub r0, r0, #2621440     ; malloc_start = relocaddr - 0x280000
4990d610: bl  mem_malloc_init
```

旧值 `0xFD000` 在新镜像里 0 处出现。

DRAM 256 MB，布局自洽：堆从 `relocaddr=0x49900000` 往下长，
栈跟着 `INIT_SP_ADDR` 一起下移（`irq_sp` 变小属正常）。

### 2.2 字段名 `md5_ok` → `md5`

后端发 `"md5_ok"`，前端读 `s.md5` ⇒ 页面 md5 一栏永远是破折号。
`tplinkinfo.c` 改成 `"md5"`，两边的命名从此必须一致。

**校验方法**：正则对比后端 `APPEND_JSON_TO_BUF("\\"(\w+)\\"` 出现的键
与前端 `s.(\w+)` 读的键。

### 2.3 新增 `oom`，不再谎报「解压失败」

`tplink_tpimg.h` 槽状态结构加 `u8 oom`；`tplink_tpimg.c` 的
`malloc(TPIMG_UBOOT_DEC_CAP)` 失败时置 `oom=1` 并 printf 原因；JSON 加
`"oom"` 字段；前端 label 链：

```js
var label = ok ? "完好"
  : (!s || !s.hdr_ok) ? "未签名"
  : (!s.md5_match)   ? "md5 不符"
  : (s.oom)          ? "内存不足"
  : "解压失败";
```

### 2.4 `active` 与 `uboot_run` 同源

原来 `tplink_slot_json()` 里写死 `"active": i == 0 ? "true" : "false"`，
于是永远把 image_1 标成运行中，而同一响应里的 `uboot_run.slot` 是
image_2 —— 页面自己跟自己矛盾。改成按 `boot_flag_slot` 判：

```c
APPEND_JSON_TO_BUF("\"active\":%s,", (running == i + 1) ? "true" : "false");
```

---

## 3. 验收

### P21b（池扩容）—— 已实证

| 项 | 修复前 | 修复后 |
|---|---|---|
| `mem_malloc_start` | `0x49803000` | `0x49680000` |
| 池大小 | 1012 KB | 2,621,440 B (2.5 MB) |
| 6 并发 `decode_ok` | 2/6 通过 | **6/6 通过**（`diag_conc3.py`，1.5 s） |
| 页面 md5 栏 | 破折号 | `617fd5b74899c8ac50b61891b589476e` ×2 |
| `tplcheck` | 两槽 OK | 两槽 OK（`decodes to 0x87bc0`） |

页面 `--dump-dom` 实测渲染：

```
image_1 | 完好 | 617fd5b74899c8ac50b61891b589476e | 头 0x800000 | 槽 0x700000
image_2 | 完好 | 运行中 | 617fd5b74899c8ac50b61891b589476e
U-Boot 2016.01-9ce3157-dirty (2026-11-06 13:17:09)
"oom": false   "decode_ok": true
```

### P21c（`active` 同源）—— 已刷入，待重启验证

槽镜像 `d0ada9f76e4f1aba9b96a559a5220cee` / crc32 `0xCB2D3108`，
`tplcheck` 两槽 `decodes to 0x87c00`（556,032 B）。

---

## 4. 顺带验证：官方固件包解析（`factory_no_fit`）

P20 修了 `tplink_tpimg.c` 里 `be32(fit) != 0xEDFE0DD0` → `0xD00DFEED`
（前者是小端读法，`be32()` 返回大端）。P21b 上首次实测通过：

```
file fw_202.bin  17302016 B  md5 412eed6d132639db3f403844c1f53831
UPLOAD 200  1.6s
{"status":"success","info":{"type":"TP-Link Official Firmware (factory container)",
 "size":"17302016","md5":"412eed6d132639db3f403844c1f53831","name":"fw_202.bin"}}
```

此前同一包返回 `{"status":"fail","info":{"type":"invalid_tplink_firmware",
"reason":"factory_no_fit"}}`。

**只做了 `/upload`（传内存 + 校验，不动 flash）。** 真写会覆盖 A 槽的
kernel+rootfs，OpenWrt 就没了 —— 要刷必须先确认意图。

---

## 5. 追溯

| 日期 | 事件 |
|---|---|
| 2026-11-06 | 用户报「image_1 解压失败 / image_2 完好，两槽 md5 相同」 |
| | 单请求 6/6 通过、6 并发 2/6 通过 → 定位到池不够 |
| | 池 1012 KB → 2.5 MB；`md5_ok`→`md5`；加 `oom` |
| | P21b 刷入，6 并发 6/6 通过，页面两槽均「完好」+ md5 有值 |
| | `active` 硬编码问题发现并修（P21c），官方包解析首次通过 |
