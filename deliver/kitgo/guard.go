package main

// 写入门禁。
//
// ★ 一律按【绝对偏移】判，绝不按 mtd 编号。
//   踩过的真 bug：按编号判的时候，写 A 槽内核（OpenWrt 下 mtd5 = 0x4880000）
//   被当成"原厂下 mtd5 = B 槽内核"，报"mtd5 只允许 restore-bslot 写"。
//
// ★ 在 PowerShell 版里还踩过一个更阴的：@{$0x4880000 = ...} 的键是 Int32，
//   查找时传 Int64，装箱后不相等，ContainsKey 一律 false ——
//   门禁【全部静默失效】。Go 里 int64 就是 int64，编译器管这事。

import "fmt"

type Action string

const (
	ActFlashUboot  Action = "flash-uboot"   // 只刷 u-boot 两槽
	ActFlashOpenWrt Action = "flash-op"     // 原厂 -> OpenWrt（写 A 槽）
	ActFlashStock  Action = "flash-stock"   // OpenWrt -> 原厂（写 A 槽）
	ActRestoreB    Action = "restore-bslot" // 修 B 槽回退
)

// 硬禁止：任何参数都绕不过，TTL 命脉
var hardDeny = map[int64]string{
	OffFactoryBoot: "factory_boot 一级 u-boot（TTL 命脉）",
	OffFactoryInfo: "factory_info 出厂信息",
	OffArt:         "art 射频校准",
	OffBootFlag:    "boot_flag 选槽标志",
}

// 受保护区域：允许写，但必须带着对应动作来，不能顺手写
var guarded = map[int64][]Action{
	OffUbootB:  {ActFlashUboot},
	OffUbootA:  {ActFlashUboot},
	OffKernelB: {ActRestoreB}, // 原厂回退，绝不被常规刷写碰
	OffRootfsB: {ActRestoreB},
	OffKernelA: {ActFlashOpenWrt, ActFlashStock}, // 工作区
	OffRootfsA: {ActFlashOpenWrt, ActFlashStock},
}

type RefusedError struct {
	Abs  int64
	Why  string
	Have Action
}

func (e *RefusedError) Error() string { return e.Why }

// CheckWrite 返回 nil 表示允许，否则返回 RefusedError。调用方必须传播错误。
func CheckWrite(abs int64, act Action) error {
	if why, bad := hardDeny[abs]; bad {
		return &RefusedError{Abs: abs, Have: act,
			Why: fmt.Sprintf("拒绝写入 %s（%s）。这是硬禁止区域，任何参数都绕不过。", hx(abs), why)}
	}
	if allow, prot := guarded[abs]; prot {
		for _, a := range allow {
			if a == act {
				return nil
			}
		}
		return &RefusedError{Abs: abs, Have: act,
			Why: fmt.Sprintf("拒绝：%s 只允许 %v 写，当前动作是 %q。", hx(abs), allow, act)}
	}
	return nil
}

// 写入区间不得撞 overlay、不得撞活分区
type Span struct{ S, E int64; N string }

var protectedSpans = []Span{
	{OffOverlayStock, 0x8000000, "原厂 overlay"},
	{OffOverlayOurs, 0x4000000, "OpenWrt overlay (wta301data)"},
}

func CheckSpan(abs, length int64, what string) error {
	end := abs + length
	for _, s := range protectedSpans {
		if abs < s.E && end > s.S {
			return fmt.Errorf("%s 的写入区间 %s..%s 与 %s 重叠，中止", what, hx(abs), hx(end), s.N)
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// ★ 同槽保护：擦自己正在运行的分区，会把系统卡死
// ---------------------------------------------------------------------------
//
// 实测事故（2026-11-07，OpenWrt 6.12.112 @192.168.1.1）：
//   A 槽在跑 OpenWrt（kernel 0x4880000 / rootfs 0x4fc0000），
//   同一会话里执行 `mtd erase kernel` 擦 0x4880000 —— 也就是自己正在用的内核分区。
//   结果：ping 通（内核网络栈还活），但 SSH 22 和 HTTP 80 全部连不上，
//         用户态进程全部卡在 MTD 全局锁上等 I/O。
//   只能断电重启；重启后一级 u-boot 发现 A 槽校验不过，自动跳到 B 槽原厂。
//
// 为什么危险：mtd erase 持有 MTD 全局锁，而 rootfs（squashfs）的读也走 MTD，
//   擦除期间所有要读 rootfs 的进程（包括 dropbear、uhttpd）全部阻塞。
//
// ⇒ 铁律：擦/写必须是【另一个槽】，不能是自己正在跑的那个。
//    原厂跑 B 槽 → 写 A 槽 ✓
//    OpenWrt 跑 A 槽 → 写 B 槽 ✓
//    OpenWrt 跑 A 槽 → 写 A 槽 ✗ 概率性死锁
//
// 同槽不是绝对禁止（历史上成功过），但必须显式确认，且要告知后果。

// 判断当前从哪个槽启动。rootfs 的物理偏移决定。
type Slot int

const (
	SlotUnknown Slot = iota
	SlotA
	SlotB
)

func (s Slot) String() string {
	switch s {
	case SlotA:
		return "A 槽"
	case SlotB:
		return "B 槽"
	}
	return "未知"
}

// 从活 rootfs 的物理偏移判断当前槽
func ActiveSlot(t *MtdTable, cmdline string) Slot {
	abs, ok := LiveRootOffset(t, cmdline)
	if !ok {
		return SlotUnknown
	}
	switch abs {
	case OffRootfsA:
		return SlotA
	case OffRootfsB:
		return SlotB
	}
	return SlotUnknown
}

// 目标绝对偏移属于哪个槽
func TargetSlot(abs int64) Slot {
	switch abs {
	case OffKernelA, OffRootfsA, OffUbootA:
		return SlotA
	case OffKernelB, OffRootfsB, OffUbootB:
		return SlotB
	}
	return SlotUnknown
}

// 同槽检查。返回 error 表示必须中止（需要 --allow-same-slot 才能过）。
func CheckSameSlot(active Slot, abs int64, what string) error {
	tgt := TargetSlot(abs)
	if active == SlotUnknown || tgt == SlotUnknown {
		warn("无法判定当前槽位，跳过同槽检查（%s @ %s）", what, hx(abs))
		return nil
	}
	if active != tgt {
		ok("交叉刷：当前跑 %s，写 %s —— 安全", active, tgt)
		return nil
	}
	if opt.AllowSameSlot {
		warn("同槽写入已获授权：%s，写 %s @ %s", active, what, hx(abs))
		warn("  擦除期间系统可能卡死（ping 通但 SSH/HTTP 全断），只能断电重启")
		return nil
	}
	return fmt.Errorf("拒绝同槽写入：板子正在跑 %s，而这次要写 %s（%s @ %s）。擦除自己正在使用的分区会持有 MTD 全局锁，rootfs 的读也被堵住 => dropbear/uhttpd 全部卡死，只能断电重启。实测发生过（OpenWrt 6.12.112 @0x4880000）。要么换个槽刷（交叉刷永远安全），要么确认后果后加 -allow-same-slot", active, tgt, what, hx(abs))
}
