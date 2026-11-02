# aria2-magisk-runsv

把 [aria2](https://aria2.github.io) 做成 **[runsvdir-magisk](https://github.com/sorubedo/runsvdir-magisk)** 的一个服务：开机由 `runsvdir` 拉起，进程挂了自动重启，日志由 `svlogd` 轮转，RPC 常驻，随时用 AriaNg 连上去加任务。

[English](README.md)

---

## 这是什么

`runsvdir-magisk` 只做一件事：装上 runit 工具并在开机时启动 `runsvdir`，服务定义交给用户自己管。这个模块就是给它补上 aria2 的服务定义、二进制和安装/更新逻辑，结构和 [openlist-magisk-runsv](https://github.com/sorubedo/openlist-magisk-runsv) 一致：

- **不重复造轮子**：进程管理、开机启动、日志收集全部交给 runsvdir-magisk，本模块不含任何守护脚本。
- **两种变体**，刷哪个包就是哪种（见下表），解决"下载的文件该归谁"这个实际问题。
- **二进制随模块走**，不依赖 Termux、不依赖其他模块。
- **配置分层**：`conf` 管"怎么启动"（端口、降权、目录），`aria2.conf` 就是 aria2 自己的配置文件，选项名和官方手册完全一致。

## 特性

- 开机自启，异常退出由 runsv 立即拉起（带 1 秒节流）
- 会话持久化：`--save-session` + `--input-file`，重启后未完成任务不丢
- RPC 常驻 `6800`，首次安装自动生成随机密钥，AriaNg / 任何 aria2 客户端可直接连
- CA 证书包自动从系统信任库生成，HTTPS 开箱可用（静态 OpenSSL 不认识 Android 的证书路径，这一步省不掉）
- 下载文件属主为 `shell`（uid 2000），和 `adb push` 一样，文件管理器、MTP、相册都能正常改名删除
- 日志按 10 MiB × 5 份轮转，不会撑爆 `/data`
- 模块"操作"按钮里的音量键菜单：启停、自启开关、看 RPC 地址、重建证书库
- 支持 4 个架构、2 个变体，CI 自动跟随 aria2 上游发版

## 依赖

| 依赖 | 说明 |
| --- | --- |
| Android Root | Magisk 20.4+ / KernelSU / APatch |
| [runsvdir-magisk](https://github.com/sorubedo/runsvdir-magisk) | **必须先装**，提供 `runsvdir`、`sv`、`chpst`、`svlogd`，以及服务目录 `/data/adb/runsvdir/service/` |
| 模块操作按钮菜单 | 需要 Magisk 27+ / KernelSU / APatch；老版本只是没有菜单，服务照常运行 |

安装器会检查 `runsvdir` 模块是否存在且未被停用，不满足直接中止，不会装出一个跑不起来的模块。

## 选哪个包

先看变体：

| | **mount**（推荐） | **nomount** |
| --- | --- | --- |
| 二进制位置 | 挂载到 `/system/bin/aria2c` | 服务目录内 `bin/aria2c` |
| 运行身份 | `shell`（uid 2000）+ 存储相关附加组 | `root` |
| 状态目录 | `/storage/emulated/0/Android/aria2` | 服务目录下 `data/` |
| 下载目录 | `/storage/emulated/0/Download/aria2` | 服务目录下 `downloads/` |
| 下载文件的属主 | `shell`，和 adb/Termux 一致，随手可改可删 | `root`，第三方 App 只能读 |
| 占用系统分区 | 是（一个只读挂载点） | 否 |
| 适合 | 手机上下载、要能直接播放/分享 | 纯后台、不想动 `/system`、要下到任意路径 |

再看架构：

| 架构 | 二进制来源 | 说明 |
| --- | --- | --- |
| `arm64-v8a` | aria2 官方 Android 构建 | NDK + bionic，openssl/c-ares/libssh2/expat/zlib 全部静态链接，只依赖系统的 libc/libm/libdl |
| `armeabi-v7a` | [abcfy2/aria2-static-build](https://github.com/abcfy2/aria2-static-build) | musl 全静态 |
| `x86_64` / `x86` | 同上 | musl 全静态 |

> **musl 架构注意**：musl 读不到 Android 的 DNS 配置（没有 `/etc/resolv.conf`），所以这些包默认在 `conf` 里写了 `DNS_SERVERS="223.5.5.5,119.29.29.29"`，通过 `--async-dns-server` 显式指定。想换 DNS 改那一行即可；arm64 走系统解析，该项保持为空。

不知道自己的架构：`getprop ro.product.cpu.abi`。

## 安装

1. 先装好 **runsvdir-magisk** 并重启，确认 `/data/adb/runsvdir/service/` 存在。
2. 在 Magisk / KernelSU 里刷入对应变体和架构的 ZIP。
3. 重启手机（mount 变体必须重启，二进制要靠管理器挂载；nomount 变体理论上几秒后就会自己起来）。
4. 检查：

```sh
sv status /data/adb/runsvdir/service/aria2
# run: /data/adb/runsvdir/service/aria2: (pid 12345) 12s
```

## 目录结构

**mount 变体**

```
/data/adb/runsvdir/service/aria2/       # 服务定义，root 所有
├── run                                 # 启动脚本（改完 sv restart 生效）
├── conf                                # 端口 / 降权 / 目录 等模块设置
├── finish                              # 退出钩子（默认空操作）
├── rpc-secret                          # 自动生成的 RPC 密钥，更新不覆盖
├── defaults/aria2.conf                 # aria2 默认配置模板
└── log/run                             # 日志子服务

/storage/emulated/0/Android/aria2/      # 运行时状态，shell 所有
├── aria2.conf                          # 首次启动从 defaults/ 复制，随便改
├── session/aria2.session               # 会话（未完成任务）
├── dht/dht.dat                         # DHT 缓存
└── ca/cacert.pem                       # 从系统证书库生成的 CA 包

/storage/emulated/0/Download/aria2/     # 下载目录
/data/adb/runsvdir/log/sv/aria2/current # 运行日志
```

**nomount 变体**只有一棵树：`/data/adb/runsvdir/service/aria2/`，里面有 `bin/`、`data/`、`downloads/`。

## 配置

### `conf`：怎么启动

| 变量 | 默认（mount / nomount） | 说明 |
| --- | --- | --- |
| `DATA_DIR` | `/storage/.../Android/aria2` / `./data` | 状态目录 |
| `DOWNLOAD_DIR` | `/storage/.../Download/aria2` / `./downloads` | `--dir`，下载落地位置 |
| `RUN_AS` | `:2000:2000:1028:1015:1023:1078` / `""` | 运行身份，chpst 数字写法；留空即 root |
| `BIN` | `/system/bin/aria2c` / `./bin/aria2c` | 二进制路径 |
| `RPC_PORT` | `6800` | RPC 端口 |
| `RPC_LISTEN_ALL` | `1` | `1` 监听所有网卡，`0` 只听 `127.0.0.1` |
| `RPC_SECRET` | `""` | 留空表示用 `rpc-secret` 文件里的密钥 |
| `DNS_SERVERS` | `""`（非 arm64 包为阿里/DNSPod） | 显式 DNS，见上文 |
| `EXTRA_ARGS` | `""` | 追加到命令行的参数，空格分隔 |
| `WAIT_DECRYPT` | `1` / `0` | 等 `/sdcard` 解密后再启动 |

`RUN_AS` 里的数字含义：`2000` shell、`1028` sdcard_r、`1015` sdcard_rw、`1023` media_rw、`1078` external_storage。用数字而不是用户名，是因为 chpst 的数字形式不查 `/etc/passwd`、`/etc/group`，各机型各版本都稳。

### `aria2.conf`：aria2 自己的配置

就是标准的 aria2 配置文件，改完 `sv restart` 生效。默认给了一套手机友好的值（`file-allocation=none`、`disk-cache=64M`、`split=8`），Tracker、UA 之类留了注释示例。

`dir`、`enable-rpc`、`rpc-secret`、`input-file`、`ca-certificate` 这些由 `run` 脚本用命令行传入，**命令行优先级高于配置文件**，写在 `aria2.conf` 里不会生效。

想恢复默认：删掉 `DATA_DIR/aria2.conf`，重启服务会自动从 `defaults/` 重新生成。

## 用 AriaNg 连

1. 在模块"操作"按钮里选 **显示 RPC 地址与密钥**，或者自己看：

```sh
cat /data/adb/runsvdir/service/aria2/rpc-secret          # 密钥
ip route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p'   # 本机 IP
```

2. 打开 [AriaNg](https://ariang.mayswind.net/)（或安卓 App 版 AriaNg Native、本地部署的 AriaNg），在 **设置 → RPC** 里填：

- 地址：`http://<手机IP>:6800/jsonrpc`
- 密钥：上一步拿到的 token

> https 页面的 AriaNg 直连 http 的 RPC 会被浏览器按混合内容拦掉。用 App 版、本地部署、或者干脆 `AriaNg` 放在同一台设备上访问 `127.0.0.1`。

安全提示：`RPC_LISTEN_ALL=1` 时同一局域网的人都能看到这个端口，密钥是唯一的门。公共 Wi-Fi 下改成 `0`。

## 常用命令

```sh
SVC=/data/adb/runsvdir/service/aria2

sv status $SVC          # 状态
sv up $SVC              # 启动（仅本次）
sv down $SVC            # 停止（仅本次）
sv restart $SVC         # 重启（改完 conf / aria2.conf 用这个）

touch $SVC/down         # 停用开机自启
rm $SVC/down            # 启用开机自启

sv-enable aria2         # 启动并启用（需 SVDIR 已设置）
sv-disable aria2        # 停止并停用

tail -f /data/adb/runsvdir/log/sv/aria2/current    # 日志
```

`sv-enable` / `sv-disable` 依赖 `SVDIR` 环境变量（runsvdir-magisk 的约定），先 `export SVDIR=/data/adb/runsvdir/service`，或者直接用上面的 `touch/rm down`。

## 操作按钮菜单

Magisk 27+ / KernelSU / APatch 的模块卡片上有"操作"按钮，点开是音量键菜单：

- **音量下**：切换选项；**音量上**：执行
- 项目：查看状态、启动/停止/重启、启用/停用自启、显示 RPC 地址、重建 CA 证书库、查看 aria2 版本

系统大版本升级或换了根证书后，点一次 **重建 CA 证书库** 即可，不用重刷模块。

## 常见问题

**装完提示缺少 runsvdir-magisk**
先装 runsvdir-magisk 并重启。安装器检查的是 `/data/adb/modules/runsvdir` 是否存在且没有 `disable`/`remove` 标记。

**`sv status` 一直是 `run: ... 1s`，日志里说找不到 `/system/bin/aria2c`**
mount 变体在安装/更新后没有立即重启。重启手机后挂载才生效。

**HTTPS 下载报证书错误**
看 `DATA_DIR/ca/cacert.pem` 是否存在且非空。空了就在操作菜单里重建；如果系统证书库确实读不到（极少数 ROM），可以自己放一个 PEM 包到那个路径。

**域名解析失败**
- arm64：走系统解析，正常不会失败；失败先查网络。
- 非 arm64：musl 静态版没有系统解析器，确认 `conf` 里 `DNS_SERVERS` 有值且服务器可达。

**下载的文件在文件管理器里删不掉**
说明你在用 nomount 变体（文件属主 root）。换 mount 变体，或者把 `RUN_AS` 改成 `:2000:2000:1028:1015:1023:1078`。

**RPC 连不上**
1. `sv status` 确认在跑；
2. `RPC_LISTEN_ALL=1`；
3. 手机和电脑在同一网段，路由器没开 AP 隔离；
4. 密钥填对（`cat $SVC/rpc-secret`）。

**端口 6800 / 51413 被占用**
改 `conf` 里的 `RPC_PORT`，BT 端口改 `aria2.conf` 里的 `listen-port` / `dht-listen-port`。

**更新模块会不会冲掉配置**
"仅更新二进制"（默认）只换 aria2c，`run`/`conf`/`aria2.conf` 全保留；"完整更新"会按安装包覆盖 `run`/`conf`，但 `aria2.conf`（在数据目录）、会话、下载文件、`rpc-secret` 都不会动。

**卸载后还剩什么**
服务目录会被删。mount 变体的 `/storage/emulated/0/Android/aria2` 和 `Download/aria2` 属于用户数据，故意保留，重装能接着用；不要了自己删。日志目录也保留。

## 构建

### GitHub Actions（推荐）

- `Build`：手动触发，只产出工件，可指定 aria2 版本
- `Build and Release`：打 tag `v1.37.0-r1` 或手动触发，构建 8 个 ZIP、发 Release、并把 `update/<variant>/<abi>.json` 提交回默认分支

本仓库默认指向 `yinmo9527/aria2-magisk-runsv`：

- `module.prop` 的 `author` 已设为 `yinmo9527`
- 发版时 CI 会把 `UPDATE_BASE` 自动设成 `https://raw.githubusercontent.com/yinmo9527/aria2-magisk-runsv/main`

fork 到别处，或者改仓库名之后，记得同步这两处（本地构建不传 `UPDATE_BASE` 就不会写 `updateJson`，不影响使用）。

维护时还有一个约定：改模块脚本就把 `revision` 文件加 1 —— 版本号是 `<aria2 版本>-r<revision>`，
`versionCode` 由它算出，不加的话管理器不会认为有新版本。

### 本地

```sh
./fetch.sh                 # 拉取 4 个架构的 aria2c 到 bin/
./package.sh               # 产出 out/*.zip + SHA256SUMS
./package.sh arm64-v8a     # 只打一个架构
```

需要 `bash`、`curl`、`unzip`，打包用 `zip`；Windows 的 Git Bash 没有 `zip` 时会自动退回 `tools/mkzip.py`（需要 Python 3）。

## 许可

**本仓库的代码（脚本、安装器、打包流程）是 MIT**，见 [LICENSE](LICENSE)。

**ZIP 里的 `aria2c` 不是 MIT**，它是 GPL-2.0-or-later，源码获取方式见 [docs/aria2-SOURCE.md](docs/aria2-SOURCE.md)。
两者是同一介质上的独立作品（脚本用 `exec` 启动二进制，没有链接成一个程序），属于 GPLv2 §2 允许的聚合，
所以 MIT 不会被传染；但对外描述这个包时别说成"纯 MIT"。

- aria2 许可证全文：[docs/aria2-COPYING](docs/aria2-COPYING)
- aria2 官方 Android 构建说明：[docs/aria2-README.android](docs/aria2-README.android)
- 二进制里静态链接的 OpenSSL 1.1.1k：[docs/aria2-LICENSE.OpenSSL](docs/aria2-LICENSE.OpenSSL)
- runit 二进制（`runsvdir`/`sv`/`chpst`/`svlogd`）**不随本模块分发**，由 [runsvdir-magisk](https://github.com/sorubedo/runsvdir-magisk) 提供，BSD 3-Clause

## 致谢

- [sorubedo/runsvdir-magisk](https://github.com/sorubedo/runsvdir-magisk) —— runit 运行时与服务目录约定
- [sorubedo/openlist-magisk-runsv](https://github.com/sorubedo/openlist-magisk-runsv) —— 双变体结构、安装器与打包流程的蓝本
- [aria2/aria2](https://github.com/aria2/aria2)、[abcfy2/aria2-static-build](https://github.com/abcfy2/aria2-static-build) —— 二进制
