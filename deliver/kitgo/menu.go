package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// 菜单。两条路分开，方向由用户选，不探测。
//
// ★ 为什么不探测（比如扫 22 端口）：
//   用户自己知道手上是什么固件。探测一旦判错，后面整条流程都错，
//   而错的代价是往错误的分区写东西。

func menu() int {
	var sess *SSHSession
	var table *MtdTable
	var kind string

	defer func() {
		if sess != nil {
			sess.Close()
			gray("已断开连接")
		}
	}()

	for {
		// ---- 选方向 ----
		if kind == "" && sess == nil {
			fmt.Println()
			fmt.Println(cCyan + " 现在板子上跑的是什么固件？" + cReset)
			fmt.Println("   [1] 原厂固件  —— 我要刷成 OpenWrt（会先 getroot，再备份原厂）")
			fmt.Println("   [2] OpenWrt  —— 我要刷回原厂（输 root 密码就能进，本来就有 root）")
			fmt.Println("   [0] 退出")
			switch ask("选 1 或 2") {
			case "0":
				return 0
			case "1":
				kind = "stock"
			case "2":
				kind = "openwrt"
			default:
				continue
			}
		}

		// ---- 连接 ----
		if sess == nil {
			if kind == "stock" {
				warn("原厂路线需要先 getroot（见 [1]）")
			}
			s, err := openSession()
			if err != nil {
				warn("%v", err)
				if ask("重试？(y/n)") != "y" {
					return 1
				}
				continue
			}
			sess = s
			t, err := readMtdTable(sess)
			if err != nil {
				warn("%v", err)
				sess.Close()
				sess = nil
				continue
			}
			table = t
			f := deviceFacts(sess)
			info("当前固件: %s  内核 %s", orDash(f.Kind), f.Kernel)
		}

		// ---- 动作菜单 ----
		if kind == "openwrt" {
			fmt.Println()
			fmt.Printf(cCyan+"   [已连上 %s   OpenWrt]"+cReset+"\n", opt.Target)
			fmt.Println("     [1] 安全审计（只读）")
			fmt.Println("     [2] ★ 一键：刷回原厂（A 槽 " + hx(OffKernelA) + " + " + hx(OffRootfsA) + "，不动 u-boot）")
			fmt.Println("     [3] 只刷 u-boot kit")
			fmt.Println("     [4] 整片备份到本机")
			fmt.Println("     [9] 看分区表与风险说明")
			fmt.Println("     [0] 退出")
			switch ask("输入序号") {
			case "0":
				return 0
			case "1":
				doAudit(sess, table)
			case "2":
				if err := doFullToStock(sess, table); err != nil {
					warn("%v", err)
				}
			case "3":
				if err := doFlashUboot(sess, table); err != nil {
					warn("%v", err)
				}
			case "4":
				if err := doBackup(sess, table); err != nil {
					warn("%v", err)
				}
			case "9":
				doExplain(table)
			default:
				warn("没有这一项")
			}
		} else {
			fmt.Println()
			fmt.Printf(cCyan+"   [已连上 %s   原厂]"+cReset+"\n", opt.Target)
			fmt.Println("     [1] 安全审计（只读）")
			fmt.Println("     [2] ★ 一键：备份原厂 -> 刷 u-boot -> 刷 OpenWrt")
			fmt.Println("     [3] 只备份原厂")
			fmt.Println("     [4] 只刷 u-boot kit")
			fmt.Println("     [5] 只刷 OpenWrt")
			fmt.Println("     [9] 看分区表与风险说明")
			fmt.Println("     [0] 退出")
			switch ask("输入序号") {
			case "0":
				return 0
			case "1":
				doAudit(sess, table)
			case "2":
				if err := doFullToOpenWrt(sess, table); err != nil {
					warn("%v", err)
				}
			case "3":
				if err := doBackup(sess, table); err != nil {
					warn("%v", err)
				}
			case "4":
				if err := doFlashUboot(sess, table); err != nil {
					warn("%v", err)
				}
			case "5":
				if err := doFlashOpenWrt(sess, table); err != nil {
					warn("%v", err)
				}
			case "9":
				doExplain(table)
			default:
				warn("没有这一项")
			}
		}
	}
}

// ---------------------------------------------------------------------------

func doExplain(t *MtdTable) {
	step("分区表（按绝对偏移，当前固件下的编号仅供参考）")
	seen := map[int64]bool{}
	for _, p := range t.Sorted() {
		if seen[p.Offset] {
			continue
		}
		seen[p.Offset] = true
		slot := ""
		switch p.Offset {
		case OffUbootA:
			slot = "u-boot A 槽"
		case OffUbootB:
			slot = "u-boot B 槽"
		case OffKernelA:
			slot = "内核 A 槽（工作区）"
		case OffRootfsA:
			slot = "rootfs A 槽（工作区）"
		case OffKernelB:
			slot = "内核 B 槽（原厂回退）"
		case OffRootfsB:
			slot = "rootfs B 槽（原厂回退）"
		case OffFactoryBoot:
			slot = "永不写：一级 u-boot / TTL 命脉"
		case OffFactoryInfo:
			slot = "永不写：出厂信息"
		case OffArt:
			slot = "永不写：射频校准"
		case OffBootFlag:
			slot = "永不写：选槽标志"
		case OffFwContainerA:
			slot = "A 槽容器（+0x80000 = 内核 A）"
		case OffFwContainerB:
			slot = "B 槽容器"
		case OffOverlayStock:
			slot = "原厂 overlay"
		}
		fmt.Printf("   mtd%-2d %-9s %-9s %s\n", p.Index, hx(p.Offset), hx(p.Size), slot)
	}
	step("风险")
	gray("· A 槽写坏 → 一级 u-boot 验不过，自动退 B 槽原厂（双向回退）")
	gray("· B 槽写坏 → 还有 A 槽，以及 TTL 的 nand write")
	gray("· mtd0/boot_flag 写坏 → 可能进不了任何系统，只能 TTL")
	gray("  所以这两个在代码里是硬禁止，任何参数都绕不过")
}

// ---------------------------------------------------------------------------

func findPkg(name string) string {
	p := filepath.Join(opt.AppDir, "images", name)
	if _, err := os.Stat(p); err == nil {
		return p
	}
	return ""
}

func findUboot() string {
	dir := filepath.Join(opt.AppDir, "uboot")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "wta301-uboot") && strings.HasSuffix(e.Name(), ".bin") {
			return filepath.Join(dir, e.Name())
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// 一次性动作（命令行）
// ---------------------------------------------------------------------------

// 在设备上跑一条命令，原样打印。调试用，不碰 flash。
func doExec() int {
	s, err := openSession()
	if err != nil {
		warn("%v", err)
		return 1
	}
	defer s.Close()
	out, err := s.Run(opt.Exec, 10*time.Minute)
	fmt.Print(out)
	if err != nil {
		return 1
	}
	return 0
}

func runOnce(action string) int {
	if action == "exec" {
		return doExec()
	}
	switch action {
	case "verify":
		s, err := openSession()
		if err != nil {
			warn("%v", err)
			return 1
		}
		defer s.Close()
		t, err := readMtdTable(s)
		if err != nil {
			warn("%v", err)
			return 1
		}
		return rr(doAudit(s, t))
	case "backup":
		s, err := openSession()
		if err != nil {
			warn("%v", err)
			return 1
		}
		defer s.Close()
		t, err := readMtdTable(s)
		if err != nil {
			warn("%v", err)
			return 1
		}
		return rr(doBackup(s, t))
	case "flash-op":
		s, err := openSession()
		if err != nil {
			warn("%v", err)
			return 1
		}
		defer s.Close()
		t, err := readMtdTable(s)
		if err != nil {
			warn("%v", err)
			return 1
		}
		return rr(doFlashOpenWrt(s, t))
	case "flash-stock":
		s, err := openSession()
		if err != nil {
			warn("%v", err)
			return 1
		}
		defer s.Close()
		t, err := readMtdTable(s)
		if err != nil {
			warn("%v", err)
			return 1
		}
		return rr(doFlashStock(s, t))
	case "flash-uboot":
		s, err := openSession()
		if err != nil {
			warn("%v", err)
			return 1
		}
		defer s.Close()
		t, err := readMtdTable(s)
		if err != nil {
			warn("%v", err)
			return 1
		}
		return rr(doFlashUboot(s, t))
	case "restore-bslot":
		s, err := openSession()
		if err != nil {
			warn("%v", err)
			return 1
		}
		defer s.Close()
		t, err := readMtdTable(s)
		if err != nil {
			warn("%v", err)
			return 1
		}
		return rr(doRestoreB(s, t))
	}
	warn("未知动作 %s", action)
	return 2
}

func rr(err error) int {
	if err != nil {
		warn("%v", err)
		return 1
	}
	return 0
}
