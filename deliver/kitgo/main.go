package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// 控制台
// ---------------------------------------------------------------------------

const (
	cRed   = "\x1b[31m"
	cGreen = "\x1b[32m"
	cCyan  = "\x1b[36m"
	cGray  = "\x1b[90m"
	cReset = "\x1b[0m"
)

var stdio = bufio.NewReader(os.Stdin)


func ok(format string, a ...any)   { fmt.Printf(cGreen+"   "+format+cReset+"\n", a...) }
func info(format string, a ...any) { fmt.Printf("   "+format+"\n", a...) }
func step(format string, a ...any) { fmt.Printf("\n"+cCyan+" "+format+cReset+"\n", a...) }
func warn(format string, a ...any) { fmt.Printf(cRed+"   "+format+cReset+"\n", a...) }
func gray(format string, a ...any) { fmt.Printf(cGray+"   "+format+cReset+"\n", a...) }

func ask(prompt string) string {
	fmt.Printf(cCyan+"   %s: "+cReset, prompt)
	line, _ := stdio.ReadString('\n')
	return strings.TrimSpace(line)
}

// ---------------------------------------------------------------------------
// 参数
// ---------------------------------------------------------------------------

type Options struct {
	Target   string
	Password string
	User     string
	Kind     string // "stock" | "openwrt"，空 = 菜单里问
	StockDir string
	BackupDir string
	AppDir   string
	DryRun   bool
	Yes      bool
	SelfTest bool
	Exec     string // -exec：在设备上跑一条命令（调试用，不碰 flash）
	Keep     bool   // 刷完不重启
	AllowSameSlot bool // 允许擦写正在运行的槽（会卡死，需显式确认）
}

var opt Options

var acts struct {
	flashOp, flashStock, flashUboot, restoreB, backup, verify bool
}

func parseFlags() {
	flag.StringVar(&opt.Target, "target", "", "设备 IP（例 192.168.1.1）")
	flag.StringVar(&opt.Password, "password", "", "OpenWrt 的 root 密码")
	flag.StringVar(&opt.User, "user", "root", "SSH 用户名")
	flag.StringVar(&opt.Kind, "kind", "", "板子上现在跑的固件：stock 或 openwrt")
	flag.StringVar(&opt.StockDir, "stock", "", "原厂镜像目录（默认 <程序目录>/stock）")
	flag.StringVar(&opt.BackupDir, "backup", "", "备份输出目录")
	flag.StringVar(&opt.AppDir, "app", "", "资源目录（默认程序所在目录）")
	flag.BoolVar(&opt.DryRun, "dry-run", false, "只算落点，不写入")
	flag.BoolVar(&opt.Yes, "yes", false, "不问确认（硬禁止区域照样拒绝）")
	flag.BoolVar(&opt.Keep, "keep", false, "刷完不重启")
	flag.BoolVar(&opt.AllowSameSlot, "allow-same-slot", false, "允许擦写当前正在运行的槽（实测会卡死系统，慎用）")
	flag.BoolVar(&opt.SelfTest, "selftest", false, "自检：镜像 md5 + 写入门禁用例")

	// 动作开关。注册成 flag 才能被 -h 看到，也不会被 flag.Parse 当成非法参数
	flag.BoolVar(&acts.flashOp, "flash-op", false, "刷 OpenWrt 到 A 槽")
	flag.BoolVar(&acts.flashStock, "flash-stock", false, "刷回原厂到 A 槽")
	flag.BoolVar(&acts.flashUboot, "flash-uboot", false, "只刷 u-boot kit 到两槽")
	flag.BoolVar(&acts.restoreB, "restore-bslot", false, "把原厂写回 B 槽")
	flag.BoolVar(&acts.backup, "backup-all", false, "整片备份所有分区到本机")
	flag.StringVar(&opt.Exec, "exec", "", "在设备上执行一条命令并打印输出（调试用）")
	flag.BoolVar(&acts.verify, "verify", false, "安全审计（只读）")
	flag.Parse()

	if opt.AppDir == "" {
		exe, err := os.Executable()
		if err == nil {
			d := exe
			if i := strings.LastIndexAny(d, `\/`); i > 0 {
				d = d[:i]
			}
			opt.AppDir = d
		} else {
			opt.AppDir, _ = os.Getwd()
		}
	}
	if opt.StockDir == "" {
		opt.StockDir = opt.AppDir + string(os.PathSeparator) + "stock"
	}
}

func main() {
	parseFlags()

	fmt.Println()
	fmt.Println(cCyan + " ====================================================================" + cReset)
	fmt.Println(cCyan + "   WTA301 一键工具（单文件 exe，零依赖）" + cReset)
	fmt.Println(cCyan + "   原厂 <-> OpenWrt 互刷 / 备份 / u-boot" + cReset)
	fmt.Println(cCyan + " ====================================================================" + cReset)

	if opt.SelfTest {
		os.Exit(runSelfTest())
	}

	// 有动作参数就直接跑，否则进菜单
	action := firstAction()
	if action != "" {
		os.Exit(runOnce(action))
	}
	os.Exit(menu())
}

// 判断是"一次性动作"还是"进菜单"
func firstAction() string {
	switch {
	case acts.flashOp:
		return "flash-op"
	case acts.flashStock:
		return "flash-stock"
	case acts.flashUboot:
		return "flash-uboot"
	case acts.restoreB:
		return "restore-bslot"
	case acts.backup:
		return "backup"
	case opt.Exec != "":
		return "exec"
	case acts.verify:
		return "verify"
	}
	return ""
}

// ---------------------------------------------------------------------------
// 设备连接
// ---------------------------------------------------------------------------

// 连上设备（OpenWrt -> SSH；原厂 -> 提示走 getroot 后 telnet）
func openSession() (*SSHSession, error) {
	ip := opt.Target
	if ip == "" {
		ip = ask("设备 IP（回车用 192.168.1.1）")
		if ip == "" {
			ip = "192.168.1.1"
		}
		opt.Target = ip
	}
	pw := opt.Password
	if pw == "" {
		pw = ask("OpenWrt 的 root 密码")
		if pw == "" {
			return nil, fmt.Errorf("没有密码。OpenWrt 的 root 密码必须由用户提供，工具不猜。")
		}
		opt.Password = pw
	}

	for i := 1; i <= 3; i++ {
		info("[连接] SSH %s@%s（第 %d/3 次）", opt.User, ip, i)
		s, err := DialSSH(ip, opt.User, pw, 12*time.Second)
		if err == nil {
			ok("已连上 %s", ip)
			return s, nil
		}
		warn("%v", err)
		if i < 3 {
			time.Sleep(2 * time.Second)
		}
	}
	return nil, fmt.Errorf("连不上 %s:22。检查网线、IP、密码。", ip)
}

// 读分区表（不要在设备上用 glob /sys/class/mtd/mtd* ——
// 目录里还有 mtd0ro..mtd13ro 这些字符设备，读它们会卡死到超时）
func readMtdTable(s *SSHSession) (*MtdTable, error) {
	const script = `for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do ` +
		`p=/sys/class/mtd/mtd$i; [ -d $p ] && echo "mtd$i $(cat $p/offset) $(cat $p/size) $(cat $p/name 2>/dev/null)"; done; true`
	out, err := s.Run(script, 30*time.Second)
	if err != nil {
		return nil, err
	}
	return ParseMtdTable(out)
}

type Facts struct {
	Kernel string
	Kind   string // stock | openwrt | ""
}

func deviceFacts(s *SSHSession) Facts {
	f := Facts{}
	out, _ := s.Run("uname -r", 20*time.Second)
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSpace(l)
		if l != "" && strings.ContainsAny(l, "0123456789") {
			f.Kernel = l
			break
		}
	}
	switch {
	case strings.HasPrefix(f.Kernel, "4.4."):
		f.Kind = "stock"
	case strings.HasPrefix(f.Kernel, "6."):
		f.Kind = "openwrt"
	}
	return f
}
