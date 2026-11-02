#!/system/bin/sh
#
# aria2 (runsv) 操作按钮。
#
# 音量下 = 移动到下一项
# 音量上 = 执行选中项
#
# 执行完一项会回到菜单，可以连续操作；选“结束”退出。
#

SVDIR=/data/adb/runsvdir/service
SVC="$SVDIR/aria2"
MODDIR="${0%/*}"
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/aria2-runsv"

# sv-enable / sv-disable 用服务名而不是全路径，必须靠 SVDIR 定位；
# 模块操作按钮的执行环境是干净的，这里替它们补上。
export SVDIR

say() { echo "$1"; }

if [ ! -d "$SVC" ]; then
    say "! 服务目录不存在: $SVC"
    say "  请重新刷入本模块"
    exit 1
fi

# 读取服务设置（端口 / 下载目录 / 降权身份），与 run 脚本用的是同一份。
[ -f "$SVC/conf" ] && . "$SVC/conf"

# nomount 变体用的是相对路径，这里统一锚定到服务目录。
case "${DATA_DIR:-}" in
    /*) ;;
    "") DATA_DIR="$SVC/data" ;;
    *) DATA_DIR="$SVC/${DATA_DIR#./}" ;;
esac
case "${DOWNLOAD_DIR:-}" in
    /*) ;;
    "") DOWNLOAD_DIR="$SVC/downloads" ;;
    *) DOWNLOAD_DIR="$SVC/${DOWNLOAD_DIR#./}" ;;
esac
: "${RPC_PORT:=6800}"
: "${RPC_LISTEN_ALL:=1}"
: "${RPC_SECRET:=}"

# 核心二进制：mount 变体在 /system/bin，nomount 变体在服务目录里。
# conf 里的相对路径（./bin/aria2c）锚定到服务目录，当前工作目录不可靠。
case "${BIN:-}" in
    /* | "") ;;
    *) BIN="$SVC/${BIN#./}" ;;
esac

BIN_CONF="${BIN:-}"
BIN=""
for candidate in "$BIN_CONF" /system/bin/aria2c "$SVC/bin/aria2c"; do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate" ]; then
        BIN="$candidate"
        break
    fi
done

if [ -x /system/bin/sv ]; then
    SV=/system/bin/sv
elif command -v sv >/dev/null 2>&1; then
    SV=sv
else
    say "! 找不到 sv，请先安装 runsvdir-magisk 并重启设备"
    exit 1
fi

if [ -x /system/bin/sv-enable ]; then
    SV_ENABLE=/system/bin/sv-enable
    SV_DISABLE=/system/bin/sv-disable
else
    SV_ENABLE=sv-enable
    SV_DISABLE=sv-disable
fi

GETEVENT=/system/bin/getevent
if [ ! -x "$GETEVENT" ]; then
    say "! 找不到 getevent，无法使用音量键菜单"
    exit 1
fi

if command -v timeout >/dev/null 2>&1; then
    TIMEOUT="timeout 5"
else
    TIMEOUT=""
fi

rpc_secret_value() {
    if [ -n "$RPC_SECRET" ]; then
        echo "$RPC_SECRET"
    elif [ -f "$SVC/rpc-secret" ]; then
        head -n 1 "$SVC/rpc-secret" 2>/dev/null
    fi
}

lan_ip() {
    local ip
    ip="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
    [ -n "$ip" ] || ip="$(getprop dhcp.wlan0.ipaddress 2>/dev/null)"
    [ -n "$ip" ] || ip="<设备IP>"
    echo "$ip"
}

# 只接受按下（value=1）事件：getevent 把按下标成 DOWN、抬起标成 UP，
# 这样一次按键只会移动一格。
read_key() {
    while :; do
        ev="$($TIMEOUT "$GETEVENT" -lqc 1 2>/dev/null)"
        case "$ev" in
            *KEY_VOLUMEUP*DOWN*) echo up; return 0 ;;
            *KEY_VOLUMEDOWN*DOWN*) echo down; return 0 ;;
        esac
    done
}

menu_count() {
    n=0
    old_ifs="$IFS"; IFS='
'
    for line in $MENU; do n=$((n + 1)); done
    IFS="$old_ifs"
    echo "$n"
}

# menu_line <index> -> "key|label"
menu_line() {
    want="$1"; n=0
    old_ifs="$IFS"; IFS='
'
    for line in $MENU; do
        n=$((n + 1))
        if [ "$n" -eq "$want" ]; then
            IFS="$old_ifs"
            echo "$line"
            return 0
        fi
    done
    IFS="$old_ifs"
    return 1
}

menu_render() {
    sel="$1"; n=0
    old_ifs="$IFS"; IFS='
'
    for line in $MENU; do
        n=$((n + 1))
        label="${line#*|}"
        if [ "$n" -eq "$sel" ]; then
            printf '  ==> %d) %s\n' "$n" "$label"
        else
            printf '      %d) %s\n' "$n" "$label"
        fi
    done
    IFS="$old_ifs"
}

build_menu() {
    MENU="status|查看状态
up|启动服务（仅本次）
down|停止服务（仅本次）
restart|重启服务
enable|启用开机自启（删除 down）
disable|停用开机自启（创建 down）
sv-enable|启动并启用
sv-disable|停止并停用
rpc|显示 RPC 地址与密钥
ca|重建 CA 证书库
version|查看 aria2 版本
quit|结束"
    COUNT="$(menu_count)"
}

do_action() {
    case "$1" in
        status)
            "$SV" status "$SVC" 2>&1
            ;;
        up)         "$SV" up "$SVC" 2>&1 ;;
        down)       "$SV" down "$SVC" 2>&1 ;;
        restart)    "$SV" restart "$SVC" 2>&1 ;;
        enable)     rm -f "$SVC/down" && echo "已启用开机自启（down 已删除）" ;;
        disable)    touch "$SVC/down" && echo "已停用开机自启（down 已创建）" ;;
        sv-enable)  "$SV_ENABLE" aria2 2>&1 && echo "已启动并启用" ;;
        sv-disable) "$SV_DISABLE" aria2 2>&1 && echo "已停止并停用" ;;
        rpc)
            secret="$(rpc_secret_value)"
            if [ "$RPC_LISTEN_ALL" = "0" ]; then
                host=127.0.0.1
            else
                host="$(lan_ip)"
            fi
            echo "RPC 地址: http://$host:$RPC_PORT/jsonrpc"
            echo "RPC 密钥: ${secret:-<未设置，任何人都能连>}"
            echo ""
            echo "客户端: AriaNg（网页版 / 安卓 App）或任何支持 aria2 RPC 的工具"
            echo "  网页版 https://ariang.mayswind.net ，或在本地部署一份 AriaNg，"
            echo "  在“AriaNg 设置 → RPC”里填上面的地址和密钥。"
            echo "  浏览器直连 http 时请用本地部署或 App 版，https 页面会被混合内容拦截。"
            echo ""
            echo "只允许本机访问: 把 $SVC/conf 里的 RPC_LISTEN_ALL 改成 0"
            ;;
        ca)
            rm -f "$DATA_DIR/ca/cacert.pem"
            "$SV" restart "$SVC" >/dev/null 2>&1
            echo "已删除旧证书包并重启服务，run 脚本会重新从系统证书库生成"
            echo "位置: $DATA_DIR/ca/cacert.pem"
            ;;
        version)
            if [ -n "$BIN" ]; then
                "$BIN" --version 2>&1 | head -n 1
                echo "二进制: $BIN"
            else
                echo "! 找不到 aria2c 二进制"
            fi
            ;;
    esac
}

# ESC[H ESC[J = 光标归位 + 清屏到末尾，菜单原地重绘而不是一行行追加。
print_frame() {
    sel="$1"
    printf '\033[H\033[J'
    echo "=============================================="
    echo "               aria2 (runsv)"
    echo "=============================================="
    echo "服务目录: $SVC"
    echo "状态目录: $DATA_DIR"
    echo "下载目录: $DOWNLOAD_DIR"
    echo "二进制:   ${BIN:-未找到}"
    echo ""
    echo "当前状态:"
    "$SV" status "$SVC" 2>&1 | while IFS= read -r l; do echo "  $l"; done
    echo ""
    menu_render "$sel"
    echo ""
    echo "【音量下 = 切换选项】  【音量上 = 执行选中项】"
    echo ""
    if [ -n "$RESULT" ]; then
        echo "上次操作: $RESULT_TITLE"
        printf '%s\n' "$RESULT" | while IFS= read -r l; do echo "  $l"; done
        echo ""
    fi
}

sel=1
RESULT=""
RESULT_TITLE=""

while :; do
    build_menu
    [ "$sel" -gt "$COUNT" ] && sel=1

    print_frame "$sel"

    key="$(read_key)"
    if [ "$key" = "down" ]; then
        sel=$((sel % COUNT + 1))
        continue
    fi

    line="$(menu_line "$sel")"
    name="${line%%|*}"
    label="${line#*|}"

    if [ "$name" = "quit" ]; then
        sleep 0.3
        break
    fi

    out="$(do_action "$name")"
    [ -n "$out" ] || out="完成"
    RESULT="$out"
    RESULT_TITLE="$label"
done

printf '\033[H\033[J'
say "已退出 aria2 (runsv) 操作菜单"
