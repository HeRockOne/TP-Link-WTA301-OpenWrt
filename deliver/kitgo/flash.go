package main

// 刷写与备份。
//
// ★ 传输全部走 SSH 管道（cat > / cat <），不开 HTTP、不依赖设备上的 wget。
//   实测 OpenWrt 的 wget 是 uclient-fetch，连工具的 HTTP 服务报
//   "Failed to send request: Operation not permitted"，得 0 字节。
//   既然 SSH 已经在跑，就别再开第二条路。
//
// ★ 每一笔写入都：写前核 md5（本地 vs 设备上 /tmp 的那份）→
//   写后回读核 md5（设备上重新 dd 出来算）→ 不符就抛错且不重启。

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// OpenWrt 完整包的布局（实测 wta301-op-25.12.6-p29.bin，总长 0x1060000）
const (
	PkgKernelOff = 0x020000
	PkgKernelLen = 0x480000
	PkgRootfsOff = 0x4a0000
	PkgRootfsLen = 0xBC0000
	PkgTotal     = 0x1060000
	BS           = 0x20000 // dd 块大小，128 KiB
)

// 上传一个本地文件到 /tmp，核 md5
func upload(s *SSHSession, local, remote string) (string, error) {
	want, err := LocalMD5(local)
	if err != nil {
		return "", err
	}
	size := int64(0)
	if st, e := os.Stat(local); e == nil {
		size = st.Size()
	}
	info("上传 %s -> %s  (%d 字节)", filepath.Base(local), remote, size)
	start := time.Now()

	if _, err := s.RunOK("rm -f "+remote, 60*time.Second); err != nil {
		return "", err
	}
	if err := s.Upload(local, remote, "", nil); err != nil {
		return "", err
	}
	got, err := s.FileSize(remote)
	if err != nil {
		return "", err
	}
	if got != size {
		return "", fmt.Errorf("上传不完整：设备 %d 字节 / 本地 %d 字节", got, size)
	}
	devMd5, err := s.RemoteMD5(remote)
	if err != nil {
		return "", err
	}
	if devMd5 != want {
		return "", fmt.Errorf("传输后 md5 不符：本地 %s  设备 %s", want, devMd5)
	}
	ok("已送达 %s  md5=%s  用时 %.1fs", remote, devMd5, time.Since(start).Seconds())
	return remote, nil
}

// 写一段数据到 flash —— 走内核 MTD 层，不碰 dd of=。
//
// srcPath 是【设备上】的路径，want 是这段数据应有的 md5（调用方从本地算好传进来）。
//
// ★ 为什么必须用 `mtd` 而不是 `dd of=/dev/mtdblockN`：
//   这颗 NAND 每页带 ECC 校验码，校验码只能由内核 MTD 层算并写进 OOB。
//   绕过内核写 = 写进去的数据没有 ECC = 之后读一律 I/O error = 分区报废。
//   实测见 mtd.go 顶部注释。
//
// `mtd -e write` 会先擦整个分区再写。-e 是必须的：
// NAND 只能 1→0，不擦直接写等于新旧数据按位与。
// 擦整个分区是安全的，因为我们的落点永远是某个槽的完整内核/rootfs，
// 同分区里没有别的要保留的东西（mtd13 容器虽然比内核大，但容器里只有内核）。
func writeChunk(s *SSHSession, act Action, srcPath string, srcOff int64, length int64,
	absOff int64, what string, want string) error {

	if err := CheckWrite(absOff, act); err != nil {
		return err
	}
	if err := CheckSpan(absOff, length, what); err != nil {
		return err
	}
	if err := CheckSameSlot(activeSlot, absOff, what); err != nil {
		return err
	}
	tg, err := currentTable.ResolveTarget(absOff, length, what)
	if err != nil {
		return err
	}

	info("%s -> %s  %s 字节  md5=%s", what, tg, hx(length), want[:8])
	if opt.DryRun {
		info("[dry-run] 不写入")
		return nil
	}

	// mtd 工具的 -p 只支持分区内偏移，不支持从源文件中间开始。
	// 需要截取源文件时先在设备上切好，不传整包。
	src := srcPath
	if srcOff != 0 || length != fileSizeOnDevice(s, srcPath) {
		cut := "/tmp/wta301-cut.bin"
		// bytes 参数是 bs= 的单位，用 1K 块能对齐任意 1K 倍数偏移
		cmd := fmt.Sprintf("dd if=%s of=%s bs=1024 skip=%d count=%d 2>/dev/null",
			srcPath, cut, srcOff/1024, length/1024)
		if _, err := s.RunOK(cmd, 10*time.Minute); err != nil {
			return fmt.Errorf("%s：切分源文件失败：%w", what, err)
		}
		src = cut
	}

	start := time.Now()
	// 两步，不能合成一步：
	//   busybox 的 mtd 不认 mtd-utils 的 `-e` 开关（报 Usage），
	//   只能先 `mtd erase` 再 `mtd write` —— 也正是 backtostock 的配方。
	//   work/docs/10-单镜像模式与新刷写方案.md:119
	//   「mtd erase → mtd write 原厂FIT → 回读 md5 校验，通过才 reboot」
	if _, err := s.RunOK("mtd erase "+tg.Part.Name, 30*time.Minute); err != nil {
		return fmt.Errorf("%s：擦除分区失败：%w", what, err)
	}
	cmd := fmt.Sprintf("mtd -q write %s %s 2>&1", src, tg.Part.Name)
	out, err := s.RunOK(cmd, 60*time.Minute)
	if err != nil {
		return fmt.Errorf("写 %s 失败（mtd write）：%w | %s", what, err, strings.TrimSpace(out))
	}
	if _, err := s.RunOK("sync", 120*time.Second); err != nil {
		return err
	}
	info("  写入完成  %.1fs（mtd erase + write，内核写 OOB/ECC）", time.Since(start).Seconds())

	// 回读校验。用裸字符设备读：读不需要解 ECC，快，且能暴露写坏的情况。
	back, err := s.Run(fmt.Sprintf("dd if=%s bs=%d skip=%d count=%d 2>/dev/null | md5sum",
		RawDev(tg.Part.Index), BS, tg.Seek, length/BS), 30*time.Minute)
	if err != nil {
		return fmt.Errorf("回读校验失败：%w", err)
	}
	got := firstField(back)
	if got != want {
		return fmt.Errorf("回读 md5 不符，写入没生效或落错位置 (期望 %s 实得 %s，没有重启，设备状态未变)", want, got)
	}
	ok("回读校验通过 %s", got)
	return nil
}

// 设备上文件的字节数（拿不到返回 -1）
func fileSizeOnDevice(s *SSHSession, path string) int64 {
	out, err := s.Run("wc -c < "+path, time.Minute)
	if err != nil {
		return -1
	}
	n, err := strconv.ParseInt(strings.TrimSpace(out), 10, 64)
	if err != nil {
		return -1
	}
	return n
}

// 写一个整文件（原厂镜像这种"整份就是一个分区"的）
func writeWhole(s *SSHSession, act Action, localPath string, absOff int64, what string) error {
	size := int64(0)
	if st, e := os.Stat(localPath); e == nil {
		size = st.Size()
	}
	if size == 0 {
		return fmt.Errorf("%s：本地文件为空 %s", what, localPath)
	}
	remote, err := upload(s, localPath, "/tmp/wta301-src.bin")
	if err != nil {
		return err
	}
	want, err := LocalMD5(localPath)
	if err != nil {
		return err
	}
	if err := writeChunk(s, act, remote, 0, size, absOff, what, want); err != nil {
		return err
	}
	s.Run("rm -f "+remote, 60*time.Second)
	return nil
}

func firstField(s string) string {
	f := strings.Fields(s)
	if len(f) == 0 {
		return ""
	}
	return f[0]
}

// 当前会话的分区表（writeChunk 需要它来算落点）
var currentTable *MtdTable

// 板子当前跑在哪个槽。writeChunk 用它做同槽保护。
var activeSlot Slot

// ---------------------------------------------------------------------------
// OpenWrt 包
// ---------------------------------------------------------------------------

func doFlashOpenWrt(s *SSHSession, t *MtdTable) error {
	currentTable = t
	activeSlot = ActiveSlot(t, mustCmd(s, "cat /proc/cmdline"))
	pkg := findPkg("wta301-op-25.12.6-p29.bin")
	if pkg == "" {
		return fmt.Errorf("找不到 images/wta301-op-25.12.6-p29.bin")
	}
	st, err := os.Stat(pkg)
	if err != nil {
		return err
	}
	if st.Size() != PkgTotal {
		return fmt.Errorf("安装包大小不对：期望 %s 实得 %s", hx(PkgTotal), hx(st.Size()))
	}
	m, err := LocalMD5(pkg)
	if err != nil {
		return err
	}
	if m != Md5OpenWrtPkg {
		return fmt.Errorf("安装包 md5 不符：期望 %s 实得 %s", Md5OpenWrtPkg, m)
	}

	f := deviceFacts(s)
	info("当前固件: %s  内核 %s", orDash(f.Kind), f.Kernel)

	step("刷 OpenWrt 到 A 槽")
	remote, err := upload(s, pkg, "/tmp/wta301-pkg.bin")
	if err != nil {
		return err
	}
	kw, err := LocalMD5Range(pkg, PkgKernelOff, PkgKernelLen)
	if err != nil {
		return err
	}
	rw, err := LocalMD5Range(pkg, PkgRootfsOff, PkgRootfsLen)
	if err != nil {
		return err
	}
	if err := writeChunk(s, ActFlashOpenWrt, remote, PkgKernelOff, PkgKernelLen, OffKernelA, "内核", kw); err != nil {
		return err
	}
	if err := writeChunk(s, ActFlashOpenWrt, remote, PkgRootfsOff, PkgRootfsLen, OffRootfsA, "rootfs", rw); err != nil {
		return err
	}
	s.Run("rm -f "+remote, 60*time.Second)
	if opt.DryRun {
		warn("dry-run：什么都没写")
		return nil
	}
	return finishFlash(s, "OpenWrt 已写入 A 槽")
}

// ---------------------------------------------------------------------------
// 原厂镜像
// ---------------------------------------------------------------------------

// 选一组原厂镜像。B 槽完好时优先用与 B 槽同版本的那组，
// 这样"刷回原厂"跟"B 槽回退"是同一个版本，行为一致。
func pickStockSet(s *SSHSession, t *MtdTable) (*StockSet, string, string, error) {
	sets := []StockSet{
		{"原厂 4.4.60 (B 槽同版)", stockImages[2], stockImages[3]},
		{"原厂 2.0.2 (A 槽原版)", stockImages[0], stockImages[1]},
	}
	// B 槽内核现在是什么，就优先用同版本的
	kp := t.ByOffset(OffKernelB)
	if kp != nil {
		if m, err := s.RemoteMD5Range(RawDev(kp.Index), SizeKernel); err == nil {
			for _, set := range sets {
				if m == set.Kernel.MD5 {
					return &set, filepath.Join(opt.StockDir, set.Kernel.File),
						filepath.Join(opt.StockDir, set.Rootfs.File), nil
				}
			}
		}
	}
	// 核不到就用 4.4.60 那组
	set := sets[0]
	return &set, filepath.Join(opt.StockDir, set.Kernel.File),
		filepath.Join(opt.StockDir, set.Rootfs.File), nil
}

func doFlashStock(s *SSHSession, t *MtdTable) error {
	currentTable = t
	activeSlot = ActiveSlot(t, mustCmd(s, "cat /proc/cmdline"))
	set, kPath, rPath, err := pickStockSet(s, t)
	if err != nil {
		return err
	}
	for _, p := range []string{kPath, rPath} {
		if _, err := os.Stat(p); err != nil {
			return fmt.Errorf("缺原厂镜像：%s", p)
		}
	}
	info("选定: %s", set.Name)

	step("刷原厂到 A 槽")
	if err := writeWhole(s, ActFlashStock, kPath, OffKernelA, "内核"); err != nil {
		return err
	}
	if err := writeWhole(s, ActFlashStock, rPath, OffRootfsA, "rootfs"); err != nil {
		return err
	}
	if opt.DryRun {
		warn("dry-run：什么都没写")
		return nil
	}
	return finishFlash(s, "原厂已写入 A 槽")
}

func doRestoreB(s *SSHSession, t *MtdTable) error {
	currentTable = t
	activeSlot = ActiveSlot(t, mustCmd(s, "cat /proc/cmdline"))
	set, kPath, rPath, err := pickStockSet(s, t)
	if err != nil {
		return err
	}
	info("选定: %s", set.Name)
	live, hasLive := LiveRootOffset(t, mustCmd(s, "cat /proc/cmdline"))
	if hasLive && live == OffRootfsB {
		return fmt.Errorf("当前正从 B 槽启动，不能覆盖它。先刷到 A 槽再修 B 槽。")
	}
	step("把原厂写回 B 槽（%s + %s）", hx(OffKernelB), hx(OffRootfsB))
	if err := writeWhole(s, ActRestoreB, kPath, OffKernelB, "内核"); err != nil {
		return err
	}
	if err := writeWhole(s, ActRestoreB, rPath, OffRootfsB, "rootfs"); err != nil {
		return err
	}
	ok("B 槽已修复")
	return nil
}

// ---------------------------------------------------------------------------
// u-boot kit
// ---------------------------------------------------------------------------

func doFlashUboot(s *SSHSession, t *MtdTable) error {
	currentTable = t
	activeSlot = ActiveSlot(t, mustCmd(s, "cat /proc/cmdline"))
	bin := findUboot()
	if bin == "" {
		return fmt.Errorf("找不到 uboot/ 目录下的 wta301-uboot-*.bin")
	}
	m, err := LocalMD5(bin)
	if err != nil {
		return err
	}
	if m != Md5UbootKit {
		return fmt.Errorf("u-boot kit md5 不符：期望 %s 实得 %s", Md5UbootKit, m)
	}
	st, _ := os.Stat(bin)
	if st.Size() != SizeUboot {
		return fmt.Errorf("u-boot kit 大小不对：期望 %s 实得 %s", hx(SizeUboot), hx(st.Size()))
	}

	step("刷 u-boot kit 到两个槽")
	gray("一级 u-boot（mtd0）不动，两个槽都坏了也能 TTL 抢救")
	if err := writeWhole(s, ActFlashUboot, bin, OffUbootA, "u-boot A 槽"); err != nil {
		return err
	}
	if err := writeWhole(s, ActFlashUboot, bin, OffUbootB, "u-boot B 槽"); err != nil {
		return err
	}
	if opt.DryRun {
		warn("dry-run：什么都没写")
		return nil
	}
	ok("两槽 u-boot 都是 kit 了")
	return nil
}

// ---------------------------------------------------------------------------
// 完整流程
// ---------------------------------------------------------------------------

func doFullToStock(s *SSHSession, t *MtdTable) error {
	// 不备份当前 OpenWrt：原厂镜像本来就在 B 槽完好躺着，
	// 刷坏了退 B 槽，想回 OpenWrt 再刷一遍安装包即可。
	// 备份这份 OpenWrt 除了多等时间、多占 140MB，没有额外保险。
	// 真要存底，菜单 [4] 是整片备份，由用户自己选。
	return doFlashStock(s, t)
}

func doFullToOpenWrt(s *SSHSession, t *MtdTable) error {
	step("[1/3] 备份原厂 15 个分区")
	if err := doBackup(s, t); err != nil {
		return fmt.Errorf("备份失败，中止（什么都没改）：%w", err)
	}
	step("[2/3] 刷 u-boot kit")
	if err := doFlashUboot(s, t); err != nil {
		return err
	}
	step("[3/3] 刷 OpenWrt")
	return doFlashOpenWrt(s, t)
}

// ---------------------------------------------------------------------------
// 备份
// ---------------------------------------------------------------------------

func doBackup(s *SSHSession, t *MtdTable) error {
	dir := opt.BackupDir
	if dir == "" {
		dir = filepath.Join(opt.AppDir, "backup-"+time.Now().Format("0102-1504"))
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	step("整片备份 -> %s", dir)

	f := deviceFacts(s)
	prefix := "mtd"
	if f.Kind != "" {
		prefix = f.Kind + "-mtd"
	}

	manifest := &bytes.Buffer{}
	bad := 0
	for _, p := range t.Sorted() {
		// 15/16 是 UBI 卷视图，不是独立区域，跳过
		if p.Index == 15 || p.Index == 16 {
			continue
		}
		name := strings.Map(func(r rune) rune {
			if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-' || r == '.' {
				return r
			}
			return '_'
		}, p.Name)
		if name == "" {
			name = "noname"
		}
		local := filepath.Join(dir, fmt.Sprintf("%s%d_%s.bin", prefix, p.Index, name))

		start := time.Now()
		n, err := download(s, RawDev(p.Index), p.Size, local)
		if err != nil {
			warn("mtd%d %s：%v", p.Index, p.Name, err)
			bad++
			continue
		}
		tag := ""
		if n < p.Size {
			tag = fmt.Sprintf(" (PARTIAL %s/%s)", hx(n), hx(p.Size))
		}
		// 落盘校验：本地重算 md5，设备上算前缀 md5，两边对
		lm, _ := LocalMD5Range(local, 0, n)
		dm, _ := s.Run(fmt.Sprintf("dd if=%s bs=%d count=%d 2>/dev/null | md5sum",
			RawDev(p.Index), BS, n/BS), 20*time.Minute)
		check := "OK"
		if n%BS != 0 {
			// 非块对齐的尾巴不参与 md5 对比（设备读不到数据尾会 EOF）
			check = "OK(前缀)"
		}
		if firstField(dm) != lm {
			check = "BAD"
			bad++
		}
		info("mtd%-2d %-16s %8s%s  %.1fs  md5=%s %s", p.Index, p.Name, hx(n), tag,
			time.Since(start).Seconds(), lm[:8], check)
		fmt.Fprintf(manifest, "%s  %d  %s  %s\n", filepath.Base(local), n, lm, p.Name)
	}

	mpath := filepath.Join(dir, "MANIFEST-"+time.Now().Format("20060102-150405")+".txt")
	os.WriteFile(mpath, manifest.Bytes(), 0o644)
	fmt.Println()
	if bad == 0 {
		ok("备份完成，%d 个分区，逐个校验通过", len(manifest.String()) - 1)
	} else {
		warn("备份有 %d 个问题", bad)
		return fmt.Errorf("%d 个分区备份/校验失败", bad)
	}
	info("清单: %s", mpath)
	return nil
}

// 从设备拉一段到本地文件。
//
// 用 sess.Start + io.CopyN，而不是 sess.Run：
//   Run 会把整段读进内存再返回，140 MB 的分区直接爆。
//   CopyN 流式落盘，并且天然处理"设备给的比要的多"（多读的部分丢掉）。
//
// 少数分区会有短读（mtd11 数据只到 0xbc0000、mtd13 只到 0x1380000），
// 内核读到数据尾返回 EOF —— 这时 CopyN 提前结束，返回实际字节数，
// 调用方标 PARTIAL 并按前缀校验。这不是错误。
func download(s *SSHSession, dev string, size int64, local string) (int64, error) {
	f, err := os.Create(local)
	if err != nil {
		return 0, err
	}
	defer f.Close()

	sess, err := s.Client.NewSession()
	if err != nil {
		return 0, err
	}
	defer sess.Close()

	// 多要一点：短读分区靠 EOF 结束，正常分区靠 CopyN 截断
	count := size/BS + 1
	cmd := fmt.Sprintf("dd if=%s bs=%d count=%d 2>/dev/null", dev, BS, count)

	stdout, err := sess.StdoutPipe()
	if err != nil {
		return 0, err
	}
	if err := sess.Start(cmd); err != nil {
		return 0, err
	}
	n, cpErr := io.CopyN(f, stdout, size)
	// 读够就主动关 channel：dd 可能还想继续吐（我们多要了 1 块），
	// 不关的话 Wait 会一直等管道里的数据被读走。
	sess.Close()
	if cpErr != nil && cpErr != io.EOF {
		return n, cpErr
	}
	if n == 0 {
		return 0, fmt.Errorf("%s 读到 0 字节", dev)
	}
	return n, nil
}

func mustCmd(s *SSHSession, cmd string) string {
	out, _ := s.Run(cmd, 20*time.Second)
	return out
}

var _ io.Reader
var _ = md5.New
var _ = hex.EncodeToString
// 收尾：问一句要不要重启。
// 刷 u-boot 不在这里重启 —— 那需要用户自己断电或走 TTL，别替他决定。
func finishFlash(s *SSHSession, what string) error {
	if opt.DryRun {
		return nil
	}
	ok("%s（两段都回读校验通过）", what)
	if opt.Keep {
		warn("按 -keep 要求不重启。手动 reboot 后生效")
		return nil
	}
	if !opt.Yes {
		fmt.Print("   现在重启？(y/N) ")
		ans, _ := stdio.ReadString('\n')
		if !strings.HasPrefix(strings.ToLower(strings.TrimSpace(ans)), "y") {
			warn("不重启。手动 reboot 后生效")
			return nil
		}
	}
	info("重启中…")
	s.Run("reboot", 20*time.Second) // 连接会断，属正常
	return nil
}