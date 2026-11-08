# feeds 怎么定版：用上游 `feeds.conf.default`，本仓不另存

`pin/` 里原来有个 `feeds.conf`，是 **0 字节空文件** —— 无意义，已删除。
这里说明实际情况。

## 结论先行

**OpenWrt v25.12.6 的 `feeds.conf.default` 本身就把 5 个 feed 钉到了具体 commit**：

```
src-git packages  https://git.openwrt.org/feed/packages.git^093d551675b1119a06ef224d419905e8d6b2af1a
src-git luci      https://git.openwrt.org/project/luci.git^75a306df84a020c57a631ef5b4c02ace56d93387
src-git routing   https://git.openwrt.org/feed/routing.git^48c808034414a2112cf9d5261a20a320e8d0d170
src-git telephony https://git.openwrt.org/feed/telephony.git^2618106d5846a4a542fdf5809f0d3ed228ce439b
src-git video     https://github.com/openwrt/video.git^094bf58da6682f895255a35a84349a79dab4bf95
```

所以只要 checkout 到 `64900e756efa667774214f9c6b17c113222e01f7`（= `v25.12.6`），
`./scripts/feeds update -i` 就会准确拿到这 5 个 commit。
**本仓不需要、也不应该再存一份 feeds.conf。**

## 已实测：官方服务器接受任意 sha 的 fetch

feed 脚本的做法是 `git fetch --depth 1 origin <sha>`，而不是 clone 再 checkout。
实测（2026-11-08）：

```
$ git fetch --depth 1 origin 75a306df84a020c57a631ef5b4c02ace56d93387
 * branch  75a306df... -> FETCH_HEAD
对象类型: commit          # git cat-file -t
```

⇒ 不需要母树/authors 的本地缓存做中转。

## ⚠️ 中国网络：`video` feed 可以跳过

| feed | 源站 | 国内通常 | 本固件是否用到 |
|---|---|---|---|
| packages | git.openwrt.org | 可达 | ✅ 大量 |
| luci | git.openwrt.org | 可达 | ✅ 全部 WebUI |
| routing | git.openwrt.org | 可达 | ✅ |
| telephony | git.openwrt.org | 可达 | ✅ |
| **video** | **github.com** | **常不可达** | ❌ **0 个包** |

实测 `pin/p31-manifest.txt`（发布版 190 包）里
`gstreamer|ffmpeg|qt5|ffplay|libv4l|v4l-utils|x264|x265` **一个都没有**，
`.config` 里 `CONFIG_PACKAGE_.*(gstreamer|ffmpeg|qt5)` 也是 0。

所以 GitHub 走不通时，把 `feeds.conf.default` 里的 `video` 那行注释掉，
然后 `./scripts/feeds update -i && ./scripts/feeds install -a` 即可，
**不影响本固件的任何功能**。

（`apply-to-2512.sh` 只检查 `package/feeds/luci` 与 `package/feeds/packages` 是否就位，
不要求 video —— 所以跳过后不会被它的自检拦住。）

