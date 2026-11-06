#!/bin/bash
# deploy-sensors.sh —— 把 CPU/温度面板推到运行中的板子（不重编固件）
#
# 用法（WSL 或任意有 ssh/pscp 的环境）：
#   bash deliver/deploy-sensors.sh
#
# 做三件事：
#   1. 写 /usr/share/rpcd/ucode/wta301                 （rpcd 数据源）
#   2. 写 /usr/share/rpcd/acl.d/luci-mod-status-wta301.json （ACL）
#   3. 写 /www/luci-static/resources/view/status/include/15_sensors.js （前端 section）
# 然后重启 rpcd 并验证 ubus 返回。
#
# 生成固件用的同一份文件在 files-rootfs/ 下；改那边之后重跑本脚本即可同步。
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/files-rootfs
PLINK=${PLINK:-"F:\GAME\DNF\PuTTY\plink.exe"}
LAPTOP=${LAPTOP:-null@192.168.112.222}
HOSTKEY=${HOSTKEY:-SHA256:MExQQkZjo7ePMbgFYMv/ZZFZuveLdah+aw40x48UEK8}

die() { echo "*** $*" >&2; exit 1; }

for f in usr/share/rpcd/ucode/wta301 \
         usr/share/rpcd/acl.d/luci-mod-status-wta301.json \
         www/luci-static/resources/view/status/include/15_sensors.js; do
	[ -f "$SRC/$f" ] || die "缺 $SRC/$f"
	# 关键：源文件末尾必须有换行，否则 heredoc 结束标记会粘到最后一行
	last=$(tail -c 1 "$SRC/$f" | od -An -c | tr -d ' ')
	[ "$last" = '\n' ] || die "$f 末尾没有换行 —— heredoc 会失效，先补 printf '\n' >> $f"
done

TMP=$(mktemp)
{
	echo '#!/bin/sh'
	echo 'echo "=== 1/3 rpcd 数据源 ==="'
	echo "cat > /usr/share/rpcd/ucode/wta301 << 'UCODE_EOF_WTA301'"
	cat "$SRC/usr/share/rpcd/ucode/wta301"
	echo 'UCODE_EOF_WTA301'
	echo 'echo "=== 2/3 ACL ==="'
	echo "cat > /usr/share/rpcd/acl.d/luci-mod-status-wta301.json << 'ACL_EOF_WTA301'"
	cat "$SRC/usr/share/rpcd/acl.d/luci-mod-status-wta301.json"
	echo 'ACL_EOF_WTA301'
	echo 'echo "=== 3/3 前端 section ==="'
	echo "cat > /www/luci-static/resources/view/status/include/15_sensors.js << 'JS_EOF_WTA301'"
	cat "$SRC/www/luci-static/resources/view/status/include/15_sensors.js"
	echo 'JS_EOF_WTA301'
	echo 'chmod 644 /usr/share/rpcd/ucode/wta301 \'
	echo '          /usr/share/rpcd/acl.d/luci-mod-status-wta301.json \'
	echo '          /www/luci-static/resources/view/status/include/15_sensors.js'
	echo 'rm -f /www/luci-static/resources/view/status/include/05_sensors.js \'
	echo '      /www/luci-static/resources/view/status/include/22_sensors.js \'
	echo '      /www/luci-static/resources/view/status/include/35_sensors.js'
	echo 'ucode -c -o /dev/null /usr/share/rpcd/ucode/wta301 && echo "  ucode 语法 OK"'
	echo '/etc/init.d/rpcd restart'
	echo 'sleep 2'
	echo 'echo ""'
	echo 'echo "=== ubus 验证 ==="'
	echo 'ubus call wta301 status | head -6'
	echo 'echo ""'
	echo 'echo "=== 页面顺序 ==="'
	echo 'ls /www/luci-static/resources/view/status/include/ | sort | sed "s/^/  /"'
} > "$TMP"
sed -i 's/\r$//' "$TMP"

echo "== 部署到板子 =="
ssh -i "${SSHKEY:-$HOME/.ssh/wta301}" -o BatchMode=yes "$LAPTOP" \
	"\"$PLINK\" -ssh -batch -hostkey $HOSTKEY -pw root root@192.168.1.1 sh -s" < "$TMP" \
	| grep -v 'WARNING\|vulnerable\|openssh.com'
rm -f "$TMP"
echo "== 完成。浏览器 Ctrl+Shift+R 强刷 http://192.168.1.1 =="
