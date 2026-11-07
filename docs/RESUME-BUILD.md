# 续跑指令（半夜触发用）

> 状态文件。构建被用户中断（白天要用电脑），等用户下指令续跑。
> 用户说下面任一触发词，立即执行 §2，不要重新问、不要重新规划。
>
> **本次目标（2026-03 记）**：不是「编出个东西」，而是把
> `docs/REPRODUCTION-VERIFICATION.md` §4 那 7 条 ⬜ 变成实测数字 ——
> 这是两仓开源后唯一还欠着对方的答案（「别人能不能构建 + 刷入成功」）。

---

## 1. 触发指令

用户说出以下**任一**即立即执行：

- `continue-build`
- `续跑构建`
- `接着编译`
- `半夜跑构建`
- 「可以开始编译了」

**不要**回答「好的需要确认吗」。直接跑。

---

## 2. 马上执行的命令

```bash
wsl -e bash -c '
set -u
cd /root/repro-verify2 || exit 1
export FORCE_UNSAFE_CONFIGURE=1
LOG=/tmp/repro-build3.log
: > $LOG
echo "=== RESUME START $(date) ===" >> $LOG
make -j6 world >> $LOG 2>&1
echo "WORLD_RC=$?" >> $LOG
echo "=== INSTALL $(date) ===" >> $LOG
make -j6 target/install >> $LOG 2>&1
echo "INSTALL_RC=$?" >> $LOG
echo "=== DONE $(date) ===" >> $LOG
echo REPRO_RESUME_DONE >> $LOG
'
```

用 `background start`，`watchPattern` 设成：
`REPRO_RESUME_DONE|WORLD_RC=[1-9]|INSTALL_RC=[1-9]`

---

## 3. 上次被中断时的状态

```
树:      /root/repro-verify2   （全新克隆 + checkout 64900e75 + apply-to-2512.sh，APPLY_RC=0）
build_dir: 9.3G 保留，未清 → 续跑是增量
工具链:   ✅ 完成（gcc 14.3.0 initial + final，交叉编译器已产出）
host 包:  ✅ 52 个完成
target 包: 19 / 88（母树基准 88）
内核:     ⬜ 未开始
报错:     0
```

上一次失败（已解决，勿重复踩）：
`tools/tar` → `configure: error: you should not run configure as root`
⇒ 必须 `export FORCE_UNSAFE_CONFIGURE=1`。**这条要写进 REPRODUCE.md。**

---

## 4. 跑完必须做的事（按顺序）

### 4.1 先看 RC

```bash
grep -E "WORLD_RC|INSTALL_RC" /tmp/repro-build3.log
```

- 任一非 0 → 查 `/tmp/repro-build3.log` 尾部 `ERROR:` 行，定位是哪个包，**不要重跑全量**
- 两个都 0 → 继续 4.2

### 4.2 出包验证（在全新树上跑仓库自己的出包脚本）

```bash
wsl -e bash -c '
cd /root && rm -rf /root/rel-repro && mkdir -p /root/rel-repro
export FORCE_UNSAFE_CONFIGURE=1
OWTREE=/root/repro-verify2 REL=/root/rel-repro \
  bash /mnt/c/Users/Sophia/Downloads/Compressed/wta301e3tyv1_cn_1_0_10_up_boot/wta301-2512/deliver/make-release.sh --version REPRO --stage P29
'
```

### 4.3 八条判据（填 `docs/REPRODUCTION-VERIFICATION.md` §4）

| # | 判据 | 命令 |
|---|---|---|
| ① | `WORLD_RC=0` | `grep WORLD_RC` |
| ② | `INSTALL_RC=0` | `grep INSTALL_RC` |
| ③ | make-release 能出四区+sysupgrade | `ls -l /root/rel-repro/pack/` |
| ④ | DTS kernel = `0x740000` | `grep -A2 "kernel@4880000" <树>/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-wta301.dts` |
| ⑤ | FIT 内嵌 DTB 的 reg 一致 | `dumpimage -T flat_dt -p 0 -o /tmp/d.dtb <itb>; fdtdump /tmp/d.dtb | grep -A3 kernel@4880000` |
| ⑥ | rootfs 里 `net-tune` md5 = `8eaaa52f11cc9a1e1e4c6e01edc421f9` | `unsquashfs -cat <rootfs.sq> usr/sbin/net-tune \| md5sum` |
| ⑦ | `15_sensors.js` + `rpcd/ucode/wta301` 在位 | `unsquashfs -l <rootfs.sq> \| grep -E "15_sensors\|ucode/wta301"` |
| ⑧ | 产物尺寸对得上 | 网页 `0x1060000` 附近 / TTL `0x1380000` / sysupgrade 量级 ~13.4MB |

### 4.4 与已发布版本比对

已发布基线（**v1.0.0 / p30**，用户手上那份，真机刷机 PASS=30/30）：
```
网页包      c823af1d54403ff811f8876dd1190101   17,170,432 B
sysupgrade  8980eb34f1652e6c78a700ce7f778d47   13,394,197 B
uboot       d0ada9f76e4f1aba9b96a559a5220cee      262,144 B
TTL        9218fb43672a08e37669873e0c93ea0a   20,447,232 B
```
（p29 的 `c5ac0911…`/`76df463d…`/`e1424fea…` 是上一版，**别再拿它比**。）

**已知 md5 必不相同**（squashfs 时间戳，见 `docs/REPRODUCTION-VERIFICATION.md` §3）。
要比的是：**尺寸量级**、**解包后文件清单与内容**、**DTS/DTS 内嵌 DTB**、**rootfs 关键文件 md5**。

### 4.5 提交

```bash
cd <repo> && git add -A && git -c user.name="wta301" -c user.email="wta301@local" commit -F - <<'EOF'
从零构建实证：全新树 make world + target/install

填充 docs/REPRODUCTION-VERIFICATION.md §4 的 8 条判据。
（跑完填实际数字，不要写「应该」）
EOF
```

---

## 5. 硬约束（不许违反）

1. **§4.3 的八条判据没全部跑完之前，不许说「已从零验证可编译」。**
2. md5 不同**不是失败** —— 先确认是 §3 解释的原因（squashfs 时间戳），不是别的问题。
3. 判据要用**命令+输出**写，不许用「看起来一样」。
4. 构建失败时先定位到具体包，**不许**盲目重跑全量（浪费 1 小时）。
5. 这条最容易被忘：**`export FORCE_UNSAFE_CONFIGURE=1`**，否则必挂在 `tools/tar`。

