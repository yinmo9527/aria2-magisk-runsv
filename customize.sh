#!/system/bin/sh
#
# aria2 (runsv) 安装脚本
#
#  * 依赖 runsvdir-magisk：服务目录固定为 /data/adb/runsvdir/service/
#  * 有两种变体，刷哪个 ZIP 就是哪种：
#      mount   : 二进制随模块挂载到 /system/bin/aria2c，降权到 shell 用户运行，
#                数据目录 /storage/emulated/0/Android/aria2，下载到
#                /storage/emulated/0/Download/aria2，文件属主和 adb push 一致
#      nomount : 二进制留在服务目录里，以 root 运行，不占用系统分区，
#                所有数据都在 /data/adb/runsvdir/service/aria2 下
#  * 安装包的 service/aria2 目录会被合并覆盖到已安装的服务目录，所以
#    run / conf / finish / log/run / 默认 aria2.conf 是一次性更新的；
#    只存在于服务目录里的东西（会话、DHT 缓存、CA 包、下载的文件）不会被删
#

SVDIR=/data/adb/runsvdir/service
SVC="$SVDIR/aria2"
DEP_URL="https://github.com/sorubedo/runsvdir-magisk"

banner() {
    ui_print "=============================================="
    ui_print "               aria2 (runsv)"
    ui_print "=============================================="
}

abort_missing_dep() {
    ui_print ""
    ui_print "############################################################"
    ui_print "#                                                          #"
    ui_print "#   安装中止：缺少依赖 runsvdir-magisk                      #"
    ui_print "#                                                          #"
    ui_print "#   请先安装并重启 runsvdir-magisk，确认以下目录存在：      #"
    ui_print "#     $SVDIR"
    ui_print "#                                                          #"
    ui_print "#   下载地址：                                              #"
    ui_print "#     $DEP_URL"
    ui_print "#                                                          #"
    ui_print "############################################################"
    ui_print ""
    abort "! Installation aborted: runsvdir-magisk is missing or inactive"
}

runsvdir_module_ok() {
    local root
    for root in /data/adb/modules /data/adb/lite_modules; do
        if [ -d "$root/runsvdir" ] \
            && [ ! -e "$root/runsvdir/remove" ] \
            && [ ! -e "$root/runsvdir/disable" ]; then
            return 0
        fi
    done
    return 1
}

# 更新方式用音量键选择，默认只更新二进制，这样脚本化刷入（读不到按键）不会卡住。
GETEVENT=/system/bin/getevent
[ -x "$GETEVENT" ] || GETEVENT="$(command -v getevent 2>/dev/null)"
HAVE_TIMEOUT=0
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
UPDATE_MODE=binary

choose_update_mode() {
    if [ -z "$GETEVENT" ] || [ "$HAVE_TIMEOUT" -eq 0 ]; then
        ui_print "- 无法读取音量键，按默认方式仅更新二进制"
        return 0
    fi

    ui_print ""
    ui_print "=============================================="
    ui_print "  检测到已安装，请选择更新方式"
    ui_print "=============================================="
    ui_print "  音量上 : 仅更新 aria2 二进制"
    ui_print "           （保留你改过的 run / conf / aria2.conf）"
    ui_print "  音量下 : 完整更新"
    ui_print "           （用安装包里的 run / conf / 默认 aria2.conf 覆盖）"
    ui_print "  30 秒内未选择则默认仅更新二进制"
    ui_print ""

    i=0
    while [ "$i" -lt 6 ]; do
        ev="$(timeout 5 "$GETEVENT" -lqc 1 2>/dev/null)"
        case "$ev" in
            *KEY_VOLUMEUP*DOWN*)
                UPDATE_MODE=binary
                ui_print "- 已选择：仅更新 aria2 二进制"
                return 0
                ;;
            *KEY_VOLUMEDOWN*DOWN*)
                UPDATE_MODE=full
                ui_print "- 已选择：完整更新"
                return 0
                ;;
        esac
        i=$((i + 1))
    done

    ui_print "- 超时未选择，按默认方式仅更新二进制"
    return 0
}

case "$ARCH" in
    arm64) ABI=arm64-v8a ;;
    arm)   ABI=armeabi-v7a ;;
    x64)   ABI=x86_64 ;;
    x86)   ABI=x86 ;;
    *)
        ui_print "! Unsupported architecture: $ARCH"
        abort "! Aborting installation"
        ;;
esac

# build-info.prop 由 package.sh 写入，记录这个包是给哪个变体/架构打的。
MODULE_VARIANT=""
TARGET_ABI=""
if [ -f "$MODPATH/build-info.prop" ]; then
    MODULE_VARIANT="$(sed -n 's/^moduleVariant=//p' "$MODPATH/build-info.prop" 2>/dev/null | head -n 1)"
    TARGET_ABI="$(sed -n 's/^targetAbi=//p' "$MODPATH/build-info.prop" 2>/dev/null | head -n 1)"
fi
case "$MODULE_VARIANT" in
    mount) ;;
    nomount) ;;
    *) MODULE_VARIANT=nomount ;;
esac

if [ "$MODULE_VARIANT" = "mount" ]; then
    BIN_SRC="$MODPATH/system/bin/aria2c"
    VARIANT_LABEL="mount（挂载到 /system/bin，降权 shell 用户）"
else
    BIN_SRC="$MODPATH/service/aria2/bin/aria2c"
    VARIANT_LABEL="nomount（服务目录内运行，root）"
fi

if [ -n "$TARGET_ABI" ] && [ "$TARGET_ABI" != "$ABI" ]; then
    ui_print "! 安装包架构: $TARGET_ABI，本机架构: $ABI"
    abort "! Please download the $ABI build for this device"
fi

if [ ! -f "$BIN_SRC" ]; then
    ui_print "! 安装包里没有 $ABI 的 aria2c（$MODULE_VARIANT 变体）"
    abort "! Please download the $ABI $MODULE_VARIANT build for this device"
fi

# 服务定义是安装包里唯一真相来源；整个目录缺失说明包是坏的，
# 继续装下去只会得到一个"安装成功但跑不起来"的模块。
if [ ! -d "$MODPATH/service/aria2" ]; then
    ui_print "! 安装包里缺少 service/aria2 目录"
    abort "! Package is incomplete, please download it again"
fi

banner
ui_print "- 设备架构: $ARCH ($ABI)"
ui_print "- 安装方式: $VARIANT_LABEL"
ui_print "- 检查依赖: runsvdir-magisk"

runsvdir_module_ok || abort_missing_dep
[ -d "$SVDIR" ] || abort_missing_dep

ui_print "- 依赖检查通过"
ui_print ""

UPDATE=0
[ -d "$SVC" ] && UPDATE=1

# 已安装的变体记在服务目录的 .variant 里，mount <-> nomount 切换时要强制
# 完整更新，否则 run / conf 会留在旧变体的版本上。
INSTALLED_VARIANT=""
if [ -f "$SVC/.variant" ]; then
    INSTALLED_VARIANT="$(head -n 1 "$SVC/.variant" 2>/dev/null)"
elif [ -f "$SVC/bin/aria2c" ]; then
    INSTALLED_VARIANT="nomount"
fi

VARIANT_CHANGED=0
if [ "$UPDATE" -eq 1 ] && [ -n "$INSTALLED_VARIANT" ] && [ "$INSTALLED_VARIANT" != "$MODULE_VARIANT" ]; then
    VARIANT_CHANGED=1
fi

if [ "$UPDATE" -eq 1 ]; then
    if [ "$VARIANT_CHANGED" -eq 1 ]; then
        UPDATE_MODE=full
        ui_print "- 检测到安装方式变化: $INSTALLED_VARIANT -> $MODULE_VARIANT"
        ui_print "- 将执行完整更新以匹配新的安装方式"
        ui_print ""
    else
        choose_update_mode
    fi
fi

# --- 安装 / 更新服务 ------------------------------------------------------
# 安装包里的 service/aria2 是这个服务的唯一真相来源，合并覆盖到已安装的
# 服务目录即可。普通文件先写临时名再 mv 到位，正在运行的二进制也能原子替换
# （避免 "text file busy"），目录则是合并而不是整体替换。

overlay_copy() {
    local oc_src="$1" oc_dst="$2" oc_entry oc_name oc_tmp
    mkdir -p "$oc_dst" || return 1
    for oc_entry in "$oc_src"/* "$oc_src"/.[!.]* "$oc_src"/..?*; do
        [ -e "$oc_entry" ] || continue
        oc_name="${oc_entry##*/}"
        if [ -d "$oc_entry" ]; then
            overlay_copy "$oc_entry" "$oc_dst/$oc_name" || return 1
        elif [ -f "$oc_entry" ]; then
            oc_tmp="$oc_dst/.$oc_name.install"
            cp -f "$oc_entry" "$oc_tmp" 2>/dev/null || { rm -f "$oc_tmp"; return 1; }
            mv -f "$oc_tmp" "$oc_dst/$oc_name" 2>/dev/null || { rm -f "$oc_tmp"; return 1; }
        fi
    done
    return 0
}

mkdir -p "$SVC"

# mount 变体的二进制属于模块的 system 负载，顺手清掉旧 nomount 留在服务
# 目录里的副本，避免两份二进制版本不一致。
if [ "$MODULE_VARIANT" = "mount" ]; then
    chmod 0755 "$MODPATH/system/bin/aria2c" 2>/dev/null
    rm -f "$SVC/bin/aria2c"
    rmdir "$SVC/bin" 2>/dev/null
fi

printf '%s\n' "$MODULE_VARIANT" > "$SVC/.variant"
chmod 0644 "$SVC/.variant" 2>/dev/null
chown 0:0 "$SVC/.variant" 2>/dev/null

if [ "$UPDATE" -eq 0 ] || [ "$UPDATE_MODE" = "full" ]; then
    overlay_copy "$MODPATH/service/aria2" "$SVC"
elif [ "$MODULE_VARIANT" = "nomount" ]; then
    # 仅更新二进制：只刷 nomount 的那份 aria2c。
    overlay_copy "$MODPATH/service/aria2/bin" "$SVC/bin"
fi

# RPC 密钥：只在第一次安装时生成，之后无论怎么更新都不会覆盖，
# 免得已经配置好的 AriaNg / 客户端集体失效。
if [ ! -s "$SVC/rpc-secret" ]; then
    SECRET="$(head -n 1 /proc/sys/kernel/random/uuid 2>/dev/null)"
    [ -n "$SECRET" ] || SECRET="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ -n "$SECRET" ] || SECRET="$(date +%s)$$"
    printf '%s\n' "$SECRET" > "$SVC/rpc-secret"
    chmod 0600 "$SVC/rpc-secret"
    chown 0:0 "$SVC/rpc-secret"
    ui_print "- 已生成 RPC 密钥: $SVC/rpc-secret"
fi

# 解压会丢可执行位，这几个已知文件显式设一遍。
chmod 0755 "$SVC/run" "$SVC/finish" "$SVC/log/run" 2>/dev/null
chmod 0644 "$SVC/conf" "$SVC/defaults/aria2.conf" 2>/dev/null
[ -f "$SVC/bin/aria2c" ] && chmod 0755 "$SVC/bin/aria2c"
chown 0:0 "$SVC/run" "$SVC/conf" "$SVC/finish" "$SVC/log/run" 2>/dev/null

# 安装器专用的暂存目录不再需要。
rm -rf "$MODPATH/bin" "$MODPATH/service"

# --- 提示 -----------------------------------------------------------------
if [ "$UPDATE" -eq 1 ]; then
    ui_print "=============================================="
    if [ "$UPDATE_MODE" = "full" ]; then
        ui_print "  更新完成：完整更新"
    else
        ui_print "  更新完成：仅 aria2 二进制"
    fi
    ui_print "=============================================="
    ui_print "  服务目录里的会话 / DHT / CA / 下载文件未被改动"
    ui_print ""
    if [ "$MODULE_VARIANT" = "mount" ]; then
        ui_print "!! mount 变体的二进制由系统挂载提供，更新后需要重启手机"
    else
        ui_print "!! 重启服务即可加载新二进制:"
        ui_print "   sv restart $SVC"
    fi
else
    ui_print "=============================================="
    ui_print "  首次安装完成"
    ui_print "=============================================="
    ui_print "  服务目录: $SVC"
    ui_print "  启动脚本: $SVC/run       （按需修改）"
    ui_print "  服务设置: $SVC/conf      （端口 / 下载目录 / 降权身份）"
    if [ "$MODULE_VARIANT" = "mount" ]; then
        ui_print "  核心二进制: /system/bin/aria2c（挂载，重启后生效）"
        ui_print "  状态目录: /storage/emulated/0/Android/aria2"
        ui_print "  下载目录: /storage/emulated/0/Download/aria2"
    else
        ui_print "  核心二进制: $SVC/bin/aria2c"
        ui_print "  状态目录: $SVC/data"
        ui_print "  下载目录: $SVC/downloads"
    fi
    ui_print "  默认 aria2 配置: 上面的状态目录/aria2.conf"
    ui_print "  当前状态: 已启用开机自启"
fi

ui_print ""
ui_print "----------------------------------------------------"
ui_print "  常用命令"
ui_print "----------------------------------------------------"
ui_print "  查看状态:     sv status $SVC"
ui_print "  启动服务:     sv up $SVC"
ui_print "  停止服务:     sv down $SVC"
ui_print "  重启服务:     sv restart $SVC"
ui_print "  停用开机自启: touch $SVC/down"
ui_print "  启用开机自启: rm $SVC/down"
ui_print "  查看 RPC 密钥: cat $SVC/rpc-secret"
ui_print "  查看日志:     tail -f /data/adb/runsvdir/log/sv/aria2/current"
ui_print "----------------------------------------------------"
if [ "$MODULE_VARIANT" = "mount" ]; then
    ui_print "- 重启手机后服务会自动拉起；也可用模块“操作”按钮菜单管理"
else
    ui_print "- 服务会在数秒内被 runsvdir 自动拉起；也可用模块“操作”按钮菜单管理"
fi
