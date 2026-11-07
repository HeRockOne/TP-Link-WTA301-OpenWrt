package main

// 设备会话。两条路：
//   OpenWrt  -> SSH（用户输 root 密码，本来就有 root）
//   原厂      -> getroot 打进去，然后走 telnet
//
// ★ 为什么用 golang.org/x/crypto/ssh 而不是调 Windows 的 ssh.exe：
//   PowerShell 版为了给 ssh.exe 喂密码，要 SSH_ASKPASS + 一个 .bat + cmd /c +
//   `< 文件` 重定向 + 脚本必须 LF + 不能用管道（管道会让 ssh 回控制台等密码）。
//   六个坑，每个都能卡半小时。这里直接密码认证，一行 Dial。

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

type SSHSession struct {
	Client *ssh.Client
	IP     string
	User   string
}

func DialSSH(ip, user, password string, timeout time.Duration) (*SSHSession, error) {
	cfg := &ssh.ClientConfig{
		User:            user,
		Auth:            []ssh.AuthMethod{ssh.Password(password)},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         timeout,
	}
	c, err := ssh.Dial("tcp", ip+":22", cfg)
	if err != nil {
		return nil, fmt.Errorf("SSH 登录 %s 失败（密码不对？）：%w", ip, err)
	}
	return &SSHSession{Client: c, IP: ip, User: user}, nil
}

func (s *SSHSession) Close() error {
	if s == nil || s.Client == nil {
		return nil
	}
	return s.Client.Close()
}

// Run 跑一条命令，返回 stdout。stderr 合并进 err。
func (s *SSHSession) Run(cmd string, timeout time.Duration) (string, error) {
	sess, err := s.Client.NewSession()
	if err != nil {
		return "", fmt.Errorf("开 session：%w", err)
	}
	defer sess.Close()

	var out, errb bytes.Buffer
	sess.Stdout = &out
	sess.Stderr = &errb

	done := make(chan error, 1)
	go func() { done <- sess.Run(cmd) }()

	select {
	case e := <-done:
		if e != nil && out.Len() == 0 {
			return "", fmt.Errorf("%s：%w %s", cmd, e, strings.TrimSpace(errb.String()))
		}
		return out.String(), nil
	case <-time.After(timeout):
		sess.Signal(ssh.SIGKILL)
		return "", fmt.Errorf("命令超时（%s）：%s", timeout, cmd)
	}
}

// RunOK 要求退出码 0，否则报错（用于 rm/mkdir/sync 这类必须成功的动作）
func (s *SSHSession) RunOK(cmd string, timeout time.Duration) (string, error) {
	sess, err := s.Client.NewSession()
	if err != nil {
		return "", err
	}
	defer sess.Close()
	var out, errb bytes.Buffer
	sess.Stdout = &out
	sess.Stderr = &errb
	done := make(chan error, 1)
	go func() { done <- sess.Run(cmd) }()
	select {
	case e := <-done:
		if e != nil {
			return out.String(), fmt.Errorf("%s 失败：%w %s", cmd, e, strings.TrimSpace(errb.String()))
		}
		return out.String(), nil
	case <-time.After(timeout):
		sess.Signal(ssh.SIGKILL)
		return "", fmt.Errorf("命令超时（%s）：%s", timeout, cmd)
	}
}

// Upload 把本地文件直接灌到设备的远端路径。
// 走 SSH 管道，不开 HTTP、不依赖 wget ——
// 实测 OpenWrt 上的 wget 是 uclient-fetch，连工具自己的 HTTP 服务报
// "Failed to send request: Operation not permitted"，得 0 字节。
func (s *SSHSession) Upload(local, remote string, mode string, progress func(int64)) error {
	f, err := os.Open(local)
	if err != nil {
		return err
	}
	defer f.Close()
	st, _ := f.Stat()

	sess, err := s.Client.NewSession()
	if err != nil {
		return err
	}
	defer sess.Close()

	var errb bytes.Buffer
	sess.Stderr = &errb
	sess.Stdin = f

	cmd := "cat > " + remote
	if mode != "" {
		cmd += " && chmod " + mode + " " + remote
	}

	done := make(chan error, 1)
	go func() { done <- sess.Run(cmd) }()

	var tick *time.Ticker
	if progress != nil {
		tick = time.NewTicker(500 * time.Millisecond)
		defer tick.Stop()
	}
	if tick == nil {
		if e := <-done; e != nil {
			return fmt.Errorf("上传失败：%w %s", e, strings.TrimSpace(errb.String()))
		}
		return nil
	}
	for {
		select {
		case e := <-done:
			if e != nil {
				return fmt.Errorf("上传失败：%w %s", e, strings.TrimSpace(errb.String()))
			}
			return nil
		case <-tick.C:
			progress(st.Size())
		}
	}
}

// 设备上算一段文件的 md5
func (s *SSHSession) RemoteMD5(path string) (string, error) {
	out, err := s.Run("md5sum "+path, 10*time.Minute)
	if err != nil {
		return "", err
	}
	f := strings.Fields(out)
	if len(f) == 0 {
		return "", fmt.Errorf("md5sum 无输出：%s", out)
	}
	h := f[0]
	if len(h) != 32 {
		return "", fmt.Errorf("md5sum 输出异常：%s", out)
	}
	return h, nil
}

// 设备上算 /dev/mtdN 前 N 字节的 md5（不整片读入内存）
func (s *SSHSession) RemoteMD5Range(dev string, size int64) (string, error) {
	out, err := s.Run(fmt.Sprintf("dd if=%s bs=131072 count=%d 2>/dev/null | md5sum", dev, size/131072), 20*time.Minute)
	if err != nil {
		return "", err
	}
	f := strings.Fields(out)
	if len(f) == 0 {
		return "", fmt.Errorf("md5sum 无输出")
	}
	return f[0], nil
}

// 从设备的某个分区带 seek 读一段，算 md5
func (s *SSHSession) RemoteMD5Skip(dev string, seekBlocks int64, size int64) (string, error) {
	if size%BS != 0 {
		return "", fmt.Errorf("长度 %s 不是 %s 的整数倍", hx(size), hx(BS))
	}
	out, err := s.Run(fmt.Sprintf("dd if=%s bs=%d skip=%d count=%d 2>/dev/null | md5sum",
		dev, BS, seekBlocks, size/BS), 20*time.Minute)
	if err != nil {
		return "", err
	}
	h := firstField(out)
	if len(h) != 32 {
		return "", fmt.Errorf("md5sum 输出异常：%s", out)
	}
	return h, nil
}

func (s *SSHSession) FileSize(path string) (int64, error) {
	out, err := s.Run(fmt.Sprintf("wc -c < %s 2>/dev/null || echo 0", path), 60*time.Second)
	if err != nil {
		return 0, err
	}
	var n int64
	fmt.Sscanf(strings.TrimSpace(out), "%d", &n)
	return n, nil
}

func LocalMD5(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := md5.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// 只算文件前 n 字节的 md5（校验写入结果用，不必整包读）
func LocalMD5Range(path string, offset, length int64) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return "", err
	}
	h := md5.New()
	if _, err := io.CopyN(h, f, length); err != nil && err != io.EOF {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
