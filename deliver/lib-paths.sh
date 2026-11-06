#!/bin/bash
# lib-paths.sh —— 所有 deliver/ 脚本共用的路径解析。
#
# 设计原则：**每个路径都能被环境变量覆盖**，不写死任何本机绝对路径。
# 这样别人 clone 到任何位置都能跑，而我们的日常流程一个字都不用改。
#
# 用法（在脚本开头）：
#   . "$(dirname "$0")/lib-paths.sh"
#
# 可覆盖的变量：
#   SRC       本仓库根目录        （默认：本文件所在目录的上一级）
#   OWTREE    OpenWrt 源码树      （默认 /root/ow2512）
#   WORK      仓库外的资产目录    （默认 $SRC/../work：备份、u-boot 槽镜像、日志）
#   REL       出包输出根          （默认 /root/rel）
#   ARGON_SRC Argon 主题源码      （默认 $WORK/pkgsrc/luci-theme-argon-v3.1.0）
#   HOSTBIN   mkfs.ubifs/ubinize 所在目录
#                                 （默认 $OWTREE/staging_dir/host/bin；
#                                   本机历史上用的是 nss-edma 那套，自动回落）

# --- 仓库根：从本文件位置推导，不依赖调用者的 cwd ---
_libdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SRC:-$(cd "$_libdir/.." && pwd)}

# --- OpenWrt 树 ---
OWTREE=${OWTREE:-/root/ow2512}

# --- 仓库外资产（备份、槽镜像、旧交付包）---
WORK=${WORK:-$(cd "$SRC/.." && pwd)/work}

# --- 出包输出 ---
REL=${REL:-/root/rel}
PACK=${PACK:-$REL/pack}
OUT=${OUT:-$REL/deliver}

# --- 第三方源码 ---
ARGON_SRC=${ARGON_SRC:-$WORK/pkgsrc/luci-theme-argon-v3.1.0}

# --- ubifs 工具 ---
# 优先用 OpenWrt 树自己的 host 工具；没有再回落到历史上用的那份。
if [ -z "${HOSTBIN:-}" ]; then
	for _c in "$OWTREE/staging_dir/host/bin" \
	          /root/nss-edma/staging_dir/host/bin; do
		if [ -x "$_c/mkfs.ubifs" ]; then
			HOSTBIN=$_c
			break
		fi
	done
	HOSTBIN=${HOSTBIN:-$OWTREE/staging_dir/host/bin}
fi

# --- 仓库内工具 ---
TOOLS=$SRC/tools

# --- 导出给子进程 ---
export SRC OWTREE WORK REL PACK OUT ARGON_SRC HOSTBIN TOOLS

# --- 通用小工具 ---
# 由于历史交付目录里的 README 必须 CRLF（Windows 记事本否则不断行），
# 而仓库里存 LF，统一用这个转换。
lf2crlf() { sed 's/\r$//; s/$/\r/'; }

need_tree() {
	[ -f "$OWTREE/Makefile" ] || {
		echo "*** 找不到 OpenWrt 树：$OWTREE"
		echo "    设置 OWTREE=/path/to/openwrt 后重试"
		return 1
	}
}

need_tool() {
	local t=$1
	[ -f "$TOOLS/$t" ] || {
		echo "*** 仓库缺工具：tools/$t"
		return 1
	}
}
