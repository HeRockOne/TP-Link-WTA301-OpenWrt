package main

// 分区表与绝对偏移。
//
// ★ 唯一真源是板上 /sys/class/mtd/mtdN/offset，不是名字，也不是编号。
//   原厂固件和我们的 OpenWrt 对同一块物理区域命名【互为主备】：
//     原厂 mtd5   = 0x0880000 (B 槽 kernel)
//     OpenWrt mtd5 = 0x4880000 (A 槽 kernel)
//   同一个数字在两个固件里指两个完全不同的分区。
//   所以程序内部一律用绝对偏移作为身份，编号只是"当前固件下的坐标"。

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// 槽位绝对偏移（物理地址，跨固件不变）
const (
	OffFactoryBoot = 0x0000000
	OffFactoryInfo = 0x0400000
	OffArt         = 0x0480000
	OffConfig      = 0x0500000
	OffUbootB      = 0x0700000
	OffKernelB     = 0x0880000
	OffRootfsB     = 0x0FC0000
	OffFwContainerB = 0x0800000 // mtd8 firmware 容器（含 kernel/rootfs B）
	OffUbootA      = 0x4700000
	OffKernelA     = 0x4880000
	OffRootfsA     = 0x4FC0000
	OffFwContainerA = 0x4800000 // mtd13 firmware_bak 容器（+0x80000 = 0x4880000）
	OffBootFlag    = 0x4000000
	OffOverlayStock = 0x6A00000 // 原厂 overlay
	OffOverlayOurs  = 0x1BC0000 // OpenWrt overlay（wta301data 卷）

	SizeKernel = 0x400000
	SizeRootfs = 0xC00000
	SizeUboot  = 0x40000
)

type Part struct {
	Index  int
	Offset int64
	Size   int64
	Name   string
}

func (p Part) End() int64 { return p.Offset + p.Size }

// 分区表：按编号索引
type MtdTable struct {
	Parts map[int]*Part
}

// 解析 `for i in ...; do echo "mtd$i $offset $size $name"; done`
func ParseMtdTable(s string) (*MtdTable, error) {
	t := &MtdTable{Parts: map[int]*Part{}}
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "mtd") {
			continue
		}
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		idx, err := strconv.Atoi(strings.TrimPrefix(f[0], "mtd"))
		if err != nil {
			continue
		}
		off, err1 := strconv.ParseInt(f[1], 10, 64)
		size, err2 := strconv.ParseInt(f[2], 10, 64)
		if err1 != nil || err2 != nil {
			continue
		}
		name := ""
		if len(f) > 3 {
			name = f[3]
		}
		t.Parts[idx] = &Part{Index: idx, Offset: off, Size: size, Name: name}
	}
	if len(t.Parts) == 0 {
		return nil, fmt.Errorf("读不到分区表（/sys/class/mtd 为空？）")
	}
	return t, nil
}

// 按绝对偏移找当前固件下的分区
func (t *MtdTable) ByOffset(off int64) *Part {
	for _, p := range t.Parts {
		if p.Offset == off {
			return p
		}
	}
	return nil
}

// 所有覆盖 [off, off+need) 且装得下的分区，按大小升序
func (t *MtdTable) Covering(off, need int64) []*Part {
	var out []*Part
	for _, p := range t.Parts {
		if p.Offset <= off && p.End() >= off+need {
			out = append(out, p)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Size < out[j].Size })
	return out
}

func (t *MtdTable) Sorted() []*Part {
	out := make([]*Part, 0, len(t.Parts))
	for _, p := range t.Parts {
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Index < out[j].Index })
	return out
}

// 写入落点：分区 + dd 的 seek 块数
type Target struct {
	Part  *Part
	Abs   int64 // 实际写入的绝对偏移
	Seek  int64 // dd seek=<块数>
	Bs    int64
}

const DDBlock = 0x20000 // 128 KiB，实测这个块大小 dd 最快且对齐所有分区

// ResolveTarget 把"要写哪个绝对偏移、写多长"翻译成"在哪个分区、seek 多少"
//
// 为什么要挑"最小的能装下的"而不是"起点正好对上的"：
//   0x4880000 同时被两个分区覆盖 ——
//     mtd10 kernel  4 MiB (0x4880000..0x4C80000)
//     mtd13 firmware_bak 容器 0x2620000 长 (0x4800000..0x6E20000，+0x80000 = 0x4880000)
//   OpenWrt 的 FIT 实占 0x41526c = 4.28 MiB > 4 MiB，
//   直写 mtd10 会被 dd 截断成砖。所以要看长度是否装得下。
//   4.4.60 原厂内核只有 4 MiB，mtd10 正好，就走 mtd10（起点正好对上）。
func (t *MtdTable) ResolveTarget(abs, need int64, what string) (*Target, error) {
	cands := t.Covering(abs, need)
	if len(cands) == 0 {
		if p := t.ByOffset(abs); p != nil {
			return nil, fmt.Errorf("%s：要写 %s 字节，但从 %s 起没有一个分区装得下（mtd%d 只有 %s）",
				what, hx(need), hx(abs), p.Index, hx(p.Size))
		}
		return nil, fmt.Errorf("找不到覆盖绝对偏移 %s 的分区（%s），分区表与预期不符", hx(abs), what)
	}
	// 起点正好对上的优先（更贴近硬件槽位语义），其次挑最小的能装下的
	var pick *Part
	for _, c := range cands {
		if c.Offset == abs {
			pick = c
			break
		}
	}
	if pick == nil {
		pick = cands[0] // Covering 已按大小升序
	}
	delta := abs - pick.Offset
	bs := int64(DDBlock)
	if delta%bs != 0 {
		return nil, fmt.Errorf("%s：落点与分区起点相差 %d 字节，不是 %s 的整数倍，无法用 dd seek 定位",
			what, delta, hx(bs))
	}
	return &Target{Part: pick, Abs: abs, Seek: delta / bs, Bs: bs}, nil
}

func (tg *Target) String() string {
	if tg.Seek == 0 {
		return fmt.Sprintf("mtd%d (%s)", tg.Part.Index, hx(tg.Part.Offset))
	}
	return fmt.Sprintf("mtd%d (%s +seek %d 块 = %s)",
		tg.Part.Index, hx(tg.Part.Offset), tg.Seek, hx(tg.Abs))
}

// 当前运行中 rootfs 的绝对偏移（判"活分区"用）。
// ★★★ 写 flash 的唯一合法方式：内核 MTD 层（mtd erase / mtd write）。
//
// 这颗 NAND 是 GigaDevice GD5F1GQ5REYIG（page 2048 / erase 128 KiB / ECC 8-bit），
// 写进去的每一页都带 ECC 校验码，校验码由【内核 MTD 层】算出来写进 OOB。
//
//   ✗ dd of=/dev/mtdN   ← 绕过 OOB/ECC，写进去的是没校验码的裸数据。
//                         实测：dd 报 "32+0 records out" 一切正常，
//                         回读 md5 完全不同（e5c55a50 vs 2868d8e9），
//                         并且之后 /dev/mtdblock5 一律 I/O error，
//                         因为读的时候 ECC 校验失败。整个分区报废。
//   ✗ dd of=/dev/mtdblockN ← 本板 OpenWrt 6.12.112 下报 I/O error，
//                         dmesg: "MTD device 'kernel' is NAND, please consider
//                         using UBI block devices instead"。原厂 4.4.60 下能用
//                         （ps1 版当时刷成功就是走这条），但不可依赖。
//   ✓ mtd -e write <file> <label>   ← 内核负责 erase + 算 ECC + 写 OOB。
//                         实测：1.84s 写完 4 MiB，回读 md5 与源完全一致。
//
// ⇒ 裸 /dev/mtdN 只用来【读】（read 不解 ECC 也能拿到原始数据，且比 mtd 工具快），
//   写一律走 `mtd`。设备上没 `mtd` 就拒绝写入，绝不降级到 dd。
//
// 参见 work/docs/11-事故复盘与正确刷写配方.md:389
//   「nand write.raw / 改 ECC 参数 → OOB 布局被写乱，整片读不出来。
//     只用 nand write，不用 .raw」
func BlockDev(idx int) string { return fmt.Sprintf("/dev/mtdblock%d", idx) }

// 裸字符设备。只读，永不写。
func RawDev(idx int) string { return fmt.Sprintf("/dev/mtd%d", idx) }

// 两个固件的 cmdline 都写 root=/dev/mtdblock6，但 6 指的是不同物理位置：
//   原厂    6 = 0x0FC0000
//   OpenWrt 6 = 0x4FC0000
// 所以必须拿编号回表查偏移，不能直接用编号。
func LiveRootOffset(t *MtdTable, cmdline string) (int64, bool) {
	i := strings.Index(cmdline, "root=/dev/mtdblock")
	if i < 0 {
		return 0, false
	}
	rest := cmdline[i+len("root=/dev/mtdblock"):]
	n := 0
	for _, c := range rest {
		if c < '0' || c > '9' {
			break
		}
		n = n*10 + int(c-'0')
	}
	if p, ok := t.Parts[n]; ok {
		return p.Offset, true
	}
	return 0, false
}

func hx(v int64) string { return fmt.Sprintf("0x%x", v) }
