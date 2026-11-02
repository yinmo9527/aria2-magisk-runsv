#!/system/bin/sh
#
# 卸载本模块会删掉 aria2 的 runsv 服务目录：
#   /data/adb/runsvdir/service/aria2
# 里面有服务定义（run / conf / finish / log/run / defaults / rpc-secret），
# 以及 nomount 变体的二进制、会话、DHT 缓存和已经下载的文件。
#
# mount 变体的状态和下载在共享存储上，属于用户数据，这里故意不动，
# 重装后会话和配置还在：
#   /storage/emulated/0/Android/aria2
#   /storage/emulated/0/Download/aria2
# 想彻底清干净就自己删这两个目录。
#
# 日志 /data/adb/runsvdir/log/sv/aria2 也保留。
#

SVC=/data/adb/runsvdir/service/aria2

# 先停服务再删目录，避免 runsv 拿着一堆半删的文件继续重启。
if [ -x /system/bin/sv ]; then
    /system/bin/sv down "$SVC" 2>/dev/null
fi

rm -rf "$SVC"
