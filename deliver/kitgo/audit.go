package main

import (
	"fmt"
	"path/filepath"
	"time"
)

// 已知镜像的 md5（全部从 flash_full_128M.bin 按偏移 dd 逐段核对过）
type Known struct {
	File string
	MD5  string
	Slot string
	Note string
}

// stock 里文件名与物理位置是【反的】，只认 md5 不认名字：
//   mtd5_kernel.bin        内容实际在 0x4880000 (A 槽 2.0.2)
//   mtd10_kernel_bak.bin   内容实际在 0x0880000 (B 槽 4.4.60)
var stockImages = []Known{
	{"mtd5_kernel.bin", "170b2188884cc040d64ac5bed7ddc365", "A 槽内核", "原厂 2.0.2 (2024-12-04)"},
	{"mtd6_rootfs.bin", "30f487419d90b2239b65035390f3b73f", "A 槽 rootfs", "原厂 2.0.2"},
	{"mtd10_kernel_bak.bin", "2868d8e975da7c641e54c72b6beb8f26", "B 槽内核", "原厂 4.4.60 (2024-11-28)"},
	{"mtd11_rootfs_bak.bin", "bf2f92ceaf509093c8854825f2dc8d5e", "B 槽 rootfs", "原厂 4.4.60"},
}

const (
	Md5UbootKit     = "d0ada9f76e4f1aba9b96a559a5220cee"
	Md5OpenWrtPkg   = "c5ac0911accd2ec48033329c383d5c4c"
	Md5OpenWrtSysup = "76df463df4d8b5acba5d52852870c127"

	// 包里两段的 md5（本地按偏移算出来的）
	Md5OpenWrtKernel = "94d7e2a76d3c113a8e115bfd722c151b" // 包 +0x20000 起 0x480000
	Md5OpenWrtRootfs = "3df05b56440aaa7210aa2e16dfd2573a" // 包 +0x4a0000 起 0xBC0000
)

// 原厂镜像组：一内核 + 一 rootfs，来源同一版本才配得起来
type StockSet struct {
	Name   string
	Kernel Known
	Rootfs Known
}

func findStockSet(dir string) (*StockSet, error) {
	found := map[string]string{} // md5 -> 路径
	for _, k := range stockImages {
		p := filepath.Join(dir, k.File)
		h, err := LocalMD5(p)
		if err != nil {
			continue
		}
		if h != k.MD5 {
			return nil, fmt.Errorf("%s 的 md5 不符：期望 %s 实得 %s（文件被改过？）", k.File, k.MD5, h)
		}
		found[k.MD5] = p
	}
	if _, ok := found[stockImages[0].MD5]; !ok {
		return nil, fmt.Errorf("%s 里找不到原厂镜像（要 4 个 .bin，见 stock/README.txt）", dir)
	}
	return &StockSet{
		Name:   "原厂 2.0.2 (2024-12-04) + 4.4.60 回退",
		Kernel: stockImages[0],
		Rootfs: stockImages[1],
	}, nil
}

const runePathSep = '\\'

// ---------------------------------------------------------------------------

func doAudit(s *SSHSession, t *MtdTable) error {
	facts := deviceFacts(s)
	step("[V1] 设备")
	info("内核 %s   固件 %s", facts.Kernel, orDash(facts.Kind))
	cmdline, _ := s.Run("cat /proc/cmdline", 20*time.Second)
	if off, ok := LiveRootOffset(t, cmdline); ok {
		info("活 rootfs 物理偏移 %s", hx(off))
	}

	step("[V2] 两槽状态")
	slots := []struct {
		label string
		kOff  int64
		rOff  int64
	}{
		{"A 槽", OffKernelA, OffRootfsA},
		{"B 槽", OffKernelB, OffRootfsB},
	}
	for _, sl := range slots {
		km, kdesc := probeKernel(s, t, sl.kOff)
		rm, rdesc := probeRootfs(s, t, sl.rOff)
		info("%s kernel %-9s md5=%s  %s", sl.label, hx(sl.kOff), km, kdesc)
		info("      rootfs %-9s md5=%s  %s", hx(sl.rOff), rm, rdesc)
	}

	step("[V3] u-boot")
	for _, u := range []struct {
		label string
		off   int64
	}{{"A 槽", OffUbootA}, {"B 槽", OffUbootB}} {
		p := t.ByOffset(u.off)
		if p == nil {
			warn("%s u-boot 分区对不上（%s）", u.label, hx(u.off))
			continue
		}
		m, _ := s.RemoteMD5Range(RawDev(p.Index), SizeUboot)
		tag := ""
		if m == Md5UbootKit {
			tag = "= 我们的 kit"
		}
		info("%s mtd%-2d %-9s md5=%s %s", u.label, p.Index, hx(p.Offset), m, tag)
	}

	step("[V4] 逃生出口")
	gray("1) 一级 u-boot 双向回退：A 槽验不过自动验 B 槽，反之亦然")
	gray("2) 一级 u-boot Web 恢复：接线到 192.168.1.1 上传固件")
	gray("3) 一级 u-boot 串口（TTL 115200）：tftp / nand read / nand erase / nand write")
	gray("4) 本工具的 --restore-bslot：把原厂镜像写回 B 槽")
	gray("5) mtd0/mtd1/mtd2/mtd14 从未被写过，TTL 可救")
	return nil
}

// A 槽内核有个坑：OpenWrt 的 FIT 实占 0x480000（4.5 MiB），
// 而 mtd10 kernel 只有 0x400000（4 MiB）—— 多出来的 0x80000 落在
// mtd13 容器里，不属于任何 kernel 分区。
// 所以判"这个槽装的是什么"不能按固定长度读一次，
// 要按两种候选长度各读一次，看命中哪个已知值。
func probeKernel(s *SSHSession, t *MtdTable, abs int64) (string, string) {
	// 先按 0x480000 读（OpenWrt 的 FIT 长度）
	if tg, err := t.ResolveTarget(abs, 0x480000, "probe"); err == nil {
		dev := RawDev(tg.Part.Index)
		if m, err := s.RemoteMD5Skip(dev, tg.Seek, 0x480000); err == nil {
			if m == Md5OpenWrtKernel {
				return m, "OpenWrt 6.12.112"
			}
		}
	}
	// 再按 0x400000 读（原厂内核长度）
	if tg, err := t.ResolveTarget(abs, SizeKernel, "probe"); err == nil {
		dev := RawDev(tg.Part.Index)
		if m, err := s.RemoteMD5Skip(dev, tg.Seek, SizeKernel); err == nil {
			switch m {
			case stockImages[0].MD5:
				return m, "原厂 2.0.2"
			case stockImages[2].MD5:
				return m, "原厂 4.4.60"
			}
			return m, "未知"
		}
	}
	return "?", "读不到"
}

func probeRootfs(s *SSHSession, t *MtdTable, abs int64) (string, string) {
	// OpenWrt rootfs 段 0xBC0000；原厂整分区 0xC00000
	if tg, err := t.ResolveTarget(abs, PkgRootfsLen, "probe"); err == nil {
		dev := RawDev(tg.Part.Index)
		if m, err := s.RemoteMD5Skip(dev, tg.Seek, PkgRootfsLen); err == nil {
			if m == Md5OpenWrtRootfs {
				return m, "OpenWrt 6.12.112"
			}
		}
	}
	if tg, err := t.ResolveTarget(abs, SizeRootfs, "probe"); err == nil {
		dev := RawDev(tg.Part.Index)
		if m, err := s.RemoteMD5Skip(dev, tg.Seek, SizeRootfs); err == nil {
			switch m {
			case stockImages[1].MD5:
				return m, "原厂 2.0.2"
			case stockImages[3].MD5:
				return m, "原厂 4.4.60"
			}
			return m, "未知"
		}
	}
	return "?", "读不到"
}

func orDash(s string) string {
	if s == "" {
		return "（未知）"
	}
	return s
}
