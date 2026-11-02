# 分发的第三方二进制与源码

本模块的 ZIP 里带有一个 aria2 可执行文件。aria2 以 **GPL-2.0-or-later** 发布，所以分发它的二进制时，
需要同时说明对应源码从哪里拿。这份文件就是那个说明。

## 二进制清单

| 架构 | 包内路径 | 版本 | 来源 |
| --- | --- | --- | --- |
| `arm64-v8a` | `system/bin/aria2c`（mount）<br>`service/aria2/bin/aria2c`（nomount） | aria2 1.37.0 | aria2 官方 Android 构建 `aria2-1.37.0-aarch64-linux-android-build1.zip` |
| `armeabi-v7a` | 同上 | aria2 1.37.0 | `abcfy2/aria2-static-build` 的 `aria2-armv7-linux-musleabihf_static` |
| `x86_64` | 同上 | aria2 1.37.0 | 同上，`aria2-x86_64-linux-musl_static` |
| `x86` | 同上 | aria2 1.37.0 | 同上，`aria2-i686-linux-musl_static` |

二进制本身**未做任何修改**，只是从上游发布包中解出 `aria2c` 并原样打包。

## 对应源码

- aria2 1.37.0 源码包：
  <https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0.tar.xz>
- aria2 源码仓库（含 `Dockerfile.android`，官方 Android 构建用的就是它）：
  <https://github.com/aria2/aria2>
- musl 静态构建的构建脚本：
  <https://github.com/abcfy2/aria2-static-build>

按 GPLv2 §3 的要求，上述源码可公开获取；如果需要离线副本或长期归档，在本仓库开 issue 索取即可，
承诺在三年内有效。

## 二进制里静态链接的第三方库

| 库 | 版本 | 许可 |
| --- | --- | --- |
| OpenSSL | 1.1.1k | OpenSSL / SSLeay，全文见 [aria2-LICENSE.OpenSSL](aria2-LICENSE.OpenSSL) |
| expat | 2.4.1 | MIT |
| zlib | 1.3.1 | zlib |
| c-ares | 1.17.2 | MIT |
| libssh2 | 1.9.0 | BSD-3-Clause |

## 关于本仓库自己的许可

本仓库的脚本、安装器、打包流程以 **MIT** 发布（见 [../LICENSE](../LICENSE)）。

它和随包分发的 aria2 二进制是相互独立的作品：脚本通过 `exec` 启动 `aria2c`，两者没有链接成一个程序，
只是在同一个 ZIP 里被一起分发——GPLv2 §2 末段明确允许这种聚合（mere aggregation），
不会把 GPL 传染到本仓库的代码上。

反过来，也**不能**把整个 ZIP 描述成 "MIT 许可的软件"：其中的 `aria2c` 仍然是 GPL-2.0-or-later。
