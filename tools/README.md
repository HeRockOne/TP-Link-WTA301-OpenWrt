# tools/ —— 工具索引

这些脚本是**这次移植过程中真正用过的**，不是演示程序。
留在这里的原因：本工程的每条结论都应该能被别人重跑一遍。

> ⚠️ 其中一部分是**当时的一次性诊断**（写在排查现场，参数写死在一个具体文件上）。
> 这类标了 `[一次性]`：留着是为了让日志里的命令可追溯，**不是通用工具**。
> 通用能力请用 `deliver/` 下的脚本（`verify-repro.sh` / `flash_release.py` 等）。

---

## 1. 三方逐层比对（AGENTS.md 第 -1 节要求的第一步）

| 工具 | 用途 |
|---|---|
| `xdiff.py` | **三方/逐层差异表**（原厂 / S7 / 25.12）。任何「某模块不工作」的判断都先跑它 |
| `fdtdiff.py` | DTB 层专用：节点数 + 属性差（L2） |

## 2. 镜像构造

| 工具 | 用途 |
|---|---|
| `mk_op_pack.py` | ImageBuilder 产物 → A 槽可直接刷的三个镜像 |
| `mk_single_img.py` | A 槽三个镜像拼成**一个**可一次刷完的大镜像 |
| `mk_web_img.py` | u-boot failsafe 网页可上传的 TPIMG 整包 |
| `mk_uboot_slot.py` | （在 `patches/uboot/build/`）u-boot.bin → 256 KB LZMA 槽镜像 |
| `mk_board2_from_art.py` | **从你自己的 ART 分区**生成 ath11k `board-2.bin` —— 别拷我们的 BDF |
| `mk_fingerprint.py` | 为发布目录生成 `FINGERPRINT.json` |
| `mk_fstools_patch.py` | 生成 fstools 补丁（`mount_root.c` 的 `done()` + `factoryreset.c` 的 `main()`） |

## 3. 校验

| 工具 | 用途 |
|---|---|
| `verify_pack.py` | 离线复核四件套（不接板子、不联网） |
| `verify_single_bin.py` | 交付前最后一道：按 u-boot 后端的判据验两个单 bin |
| `parse_board2.py` | 解析 `board-2.bin` 容器：variant 名 / BDF 大小 / 内容 md5 |
| `verify_result_fix.py` | 证明「空 body 的 POST `/result` 不再返回 400」，且**不写一格 flash** |

## 4. 串口 / 远程控制

| 工具 | 用途 |
|---|---|
| `rawserial.py` | 把 COM 口原样搬到 stdin/stdout（给 SSH 通道用） |
| `plink_serial.py` | 串口桥（本机侧），走 plink 的 SSH 通道 |
| `utel.py` | u-boot telnet 控制台驱动（在另一台机器上跑） |

## 5. u-boot failsafe 网页刷机

| 工具 | 用途 |
|---|---|
| `web_flash.py` | 完整走一遍 Web failsafe 刷机：`/upload` → `/result` → `/reboot` |
| `webflash_lap.py` | 在另一台机器上把槽镜像推进板子（u-boot httpd） |
| `flash_p20c.py` | 用「修好后的前端行为」刷 u-boot 槽镜像 |

## 6. `[一次性]` 现场诊断

这些写在排查现场，参数硬编码，只对当时的日志有意义：

| 工具 | 当时要回答的问题 |
|---|---|
| `diag_conc2.py` | 并发失败时是「malloc 失败」还是「LZMA 坏流」 |
| `diag_conc3.py` | 并发下 `decode_ok` 是否全部 true、md5 一栏是否有值 |
| `fwtry.py` | 官方包能不能过 `/upload` 的解析（只传内存+校验，不动 flash） |
| `scan_fake_strings.py` | — |

## 7. `getroot/`

免拆机拿原厂 root 的脚本，单独成目录：见 [`getroot/README.md`](getroot/README.md)。

---

## 约定

1. **只用 Python 标准库**，除非脚本自己声明依赖。`web_flash.py` / `rawserial.py` 用 `pyserial`。
2. **默认不写 flash**：凡是能「传内存 + 校验」验完的，绝不先烧 flash。
   真刷写的入口统一在 `deliver/flash_release.py`。
3. **不要往这里加一次性脚本**。一次性排查看完就删，或者写进 `docs/` 当日志。
   这里已有的一批是历史包袱，保留只为追溯。

