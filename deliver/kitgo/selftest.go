package main

// 自检：镜像 md5 + 写入门禁用例。
// 门禁用例必须真的抛错、也能真的放行 ——
// PowerShell 版曾经因为 Int32/Int64 装箱失败，门禁【全部静默放行】，
// 只有自检才发现。这里保留同样的用例表。

import (
	"fmt"
	"os"
	"path/filepath"
)

type guardCase struct {
	Off  int64
	Act  Action
	Want bool
	Why  string
}

var guardCases = []guardCase{
	{OffFactoryBoot, ActFlashOpenWrt, false, "factory_boot 一级 u-boot，TTL 命脉"},
	{OffFactoryInfo, ActFlashStock, false, "factory_info 出厂信息"},
	{OffArt, ActFlashUboot, false, "art 射频校准"},
	{OffBootFlag, ActFlashOpenWrt, false, "boot_flag"},
	{OffUbootB, ActFlashOpenWrt, false, "u-boot B 槽只能由 flash-uboot 写"},
	{OffUbootA, ActRestoreB, false, "u-boot A 槽只能由 flash-uboot 写"},
	{OffKernelB, ActFlashStock, false, "内核 B 槽（原厂回退）只能由 restore-bslot 写"},
	{OffRootfsB, ActFlashUboot, false, "rootfs B 槽只能由 restore-bslot 写"},
	{OffKernelB, ActFlashOpenWrt, false, "内核 B 槽不能被 flash-op 碰"},
	{OffKernelA, ActFlashOpenWrt, true, "内核 A 槽，flash-op 合法"},
	{OffKernelA, ActFlashStock, true, "内核 A 槽，flash-stock 合法"},
	{OffRootfsA, ActFlashOpenWrt, true, "rootfs A 槽，flash-op 合法"},
	{OffRootfsA, ActFlashStock, true, "rootfs A 槽，flash-stock 合法"},
	{OffUbootB, ActFlashUboot, true, "u-boot B 槽，flash-uboot 合法"},
	{OffUbootA, ActFlashUboot, true, "u-boot A 槽，flash-uboot 合法"},
	{OffKernelB, ActRestoreB, true, "内核 B 槽，restore-bslot 合法"},
	{OffRootfsB, ActRestoreB, true, "rootfs B 槽，restore-bslot 合法"},
}

func runSelfTest() int {
	bad := 0

	step("文件")
	type want struct{ rel, md5 string }
	for _, w := range []want{
		{filepath.Join("images", "wta301-op-25.12.6-p29.bin"), Md5OpenWrtPkg},
		{filepath.Join("images", "wta301-op-25.12.6-p29-sysupgrade.bin"), Md5OpenWrtSysup},
		{filepath.Join("uboot", "wta301-uboot-p21c.bin"), Md5UbootKit},
	} {
		p := filepath.Join(opt.AppDir, w.rel)
		h, err := LocalMD5(p)
		if err != nil {
			warn("%s 缺失", w.rel)
			bad++
			continue
		}
		if h == w.md5 {
			ok("%s  %s", w.rel, h)
		} else {
			warn("%s md5 不符 期望 %s 实得 %s", w.rel, w.md5, h)
			bad++
		}
	}

	step("原厂镜像")
	for _, k := range stockImages {
		p := filepath.Join(opt.StockDir, k.File)
		h, err := LocalMD5(p)
		if err != nil {
			warn("%s 缺失（%s）", k.File, k.Slot)
			bad++
			continue
		}
		if h == k.MD5 {
			ok("%s  %s  %s", k.File, h, k.Note)
		} else {
			warn("%s md5 不符 期望 %s 实得 %s", k.File, k.MD5, h)
			bad++
		}
	}

	step("写入门禁")
	for _, c := range guardCases {
		err := CheckWrite(c.Off, c.Act)
		allowed := err == nil
		if allowed == c.Want {
			ok("%-9s %-14s -> %s  (%s)", hx(c.Off), c.Act, verdict(allowed), c.Why)
		} else {
			warn("%-9s %-14s -> 期望 %s 实际 %s  (%s)",
				hx(c.Off), c.Act, verdict(c.Want), verdict(allowed), c.Why)
			bad++
		}
	}

	step("落点解析")
	mt := &MtdTable{Parts: map[int]*Part{
		10: {Index: 10, Offset: OffKernelA, Size: 0x400000, Name: "kernel"},
		13: {Index: 13, Offset: OffFwContainerA, Size: 0x2620000, Name: "firmware_bak"},
		5:  {Index: 5, Offset: OffKernelB, Size: 0x400000, Name: "kernel"},
		6:  {Index: 6, Offset: OffRootfsA, Size: 0xC00000, Name: "rootfs"},
	}}
	for _, c := range []struct {
		off, need int64
		wantMtd   int
		wantSeek  int64
		why       string
	}{
		{OffKernelA, 0x41526c, 13, 4, "OpenWrt FIT 4.28MiB > mtd10 的 4MiB，必须走 mtd13 容器 +seek"},
		{OffKernelA, 0x400000, 10, 0, "原厂内核正好 4MiB，直写 mtd10"},
		{OffRootfsA, 0xC00000, 6, 0, "rootfs 正好 0xC00000，直写 mtd6"},
	} {
		tg, err := mt.ResolveTarget(c.off, c.need, "测试")
		if err != nil {
			warn("%s：%v", c.why, err)
			bad++
			continue
		}
		if tg.Part.Index == c.wantMtd && tg.Seek == c.wantSeek {
			ok("%-9s need %-8s -> %s", hx(c.off), hx(c.need), tg)
		} else {
			warn("%-9s need %-8s -> 期望 mtd%d seek=%d 实得 %s",
				hx(c.off), hx(c.need), c.wantMtd, c.wantSeek, tg)
			bad++
		}
	}

	fmt.Println()
	if bad == 0 {
		fmt.Println(cGreen + " 自检通过，可以开始。" + cReset)
	} else {
		fmt.Println(cRed + fmt.Sprintf(" 自检有 %d 项问题，先修这些再动设备。", bad) + cReset)
	}
	fmt.Println()
	if bad != 0 {
		return 1
	}
	return 0
}

func verdict(b bool) string {
	if b {
		return "允许"
	}
	return "拒绝"
}

var _ = os.Exit
