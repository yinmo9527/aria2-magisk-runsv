#!/usr/bin/env bash
#
# 打 Magisk 模块包：2 个变体 × 若干架构，每个 ZIP 只装一种组合。
# 先跑 ./fetch.sh 准备好 bin/<abi>/aria2c。
#
# 用法：
#   ./package.sh                          # 全架构 × 全部变体
#   ./package.sh arm64-v8a                # 只打某个架构
#   UPDATE_BASE=https://raw.githubusercontent.com/yinmo9527/aria2-magisk-runsv/main ./package.sh
#
# 设置 UPDATE_BASE 时会把 updateJson 写进 module.prop，模块管理器据此检查更新。
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="aria2-runsv"
OUT_DIR="$PROJECT_DIR/out"
SUPPORTED_ABIS=(arm64-v8a armeabi-v7a x86_64 x86)
VARIANTS=(mount nomount)
BINARY=aria2c
COMMON_FILES=(META-INF customize.sh uninstall.sh action.sh module.prop)

# update/<variant>/<abi>.json 的raw 前缀；留空表示开发构建，不写 updateJson。
UPDATE_BASE="${UPDATE_BASE:-}"

# musl 静态构建读不到 Android 的 DNS 配置，必须显式给服务器。
MUSL_DNS_DEFAULT="${MUSL_DNS_DEFAULT:-223.5.5.5,119.29.29.29}"

usage() {
    echo "用法: $0 [arm64-v8a|armeabi-v7a|x86_64|x86 ...]"
    echo "不带架构参数时打包全部架构。先跑 fetch.sh 准备二进制。"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

if [ "$#" -gt 0 ]; then
    ABIS=("$@")
else
    ABIS=("${SUPPORTED_ABIS[@]}")
fi

for ABI in "${ABIS[@]}"; do
    ok=0
    for s in "${SUPPORTED_ABIS[@]}"; do
        [ "$ABI" = "$s" ] && ok=1
    done
    if [ "$ok" -ne 1 ]; then
        echo "ERROR: 不支持的架构: $ABI" >&2
        usage >&2
        exit 1
    fi
done

# --- 版本号 -----------------------------------------------------------------
# version = <aria2 版本>-r<revision>，versionCode = 主*1e6 + 次*1e4 + 修订*1e2 + rev
# 1.37.0-r1 -> 1370001，远小于 Magisk 的 32 位 Int 上限。
REV="$(head -n 1 "$PROJECT_DIR/revision" | tr -d ' \r\n')"
[ -n "$REV" ] || REV=1

if [ -f "$OUT_DIR/upstream-versions.env" ]; then
    # shellcheck disable=SC1091
    . "$OUT_DIR/upstream-versions.env"
    ARIA2_VERSION="${ARIA2_VERSION:?upstream-versions.env 里缺少 ARIA2_VERSION}"
else
    # 没跑 fetch.sh 时退回 module.prop 里已经写好的版本，方便离线改脚本
    ARIA2_VERSION="$(sed -n 's/^version=//p' "$PROJECT_DIR/module.prop" | head -n 1)"
    ARIA2_VERSION="${ARIA2_VERSION%%-r*}"
fi

IFS=. read -r V_MAJ V_MIN V_PAT <<<"$ARIA2_VERSION"
MODULE_VERSION="${ARIA2_VERSION}-r${REV}"
MODULE_VERSION_CODE=$((10#$V_MAJ * 1000000 + 10#$V_MIN * 10000 + 10#$V_PAT * 100 + 10#$REV))

echo "=> 模块版本: $MODULE_VERSION (versionCode $MODULE_VERSION_CODE)"

# --- 变体元数据 -------------------------------------------------------------
variant_metadata() {
    case "$1" in
        mount)
            VARIANT_NAME="aria2 (runsv, mount)"
            VARIANT_DESC="aria2 下载服务，runsv 托管。二进制挂载到 /system/bin/aria2c 并以 shell 用户运行，配置和下载都在共享存储上，手机上的文件管理器和电脑都能直接处理。"
            ;;
        *)
            VARIANT_NAME="aria2 (runsv, no-mount)"
            VARIANT_DESC="aria2 下载服务，runsv 托管。二进制和全部数据都留在服务目录内，以 root 运行，不占用系统分区。"
            ;;
    esac
}

# 只替换指定字段，保持 module.prop 的行序；UPDATE_BASE 非空时补 updateJson。
stamp_module_prop() {
    local file="$1" update_url="${2:-}" disp_name="$3" disp_desc="$4" tmp="$1.tmp"
    while IFS= read -r line; do
        case "$line" in
            name=*) echo "name=$disp_name" ;;
            description=*) echo "description=$disp_desc" ;;
            version=*) echo "version=$MODULE_VERSION" ;;
            versionCode=*) echo "versionCode=$MODULE_VERSION_CODE" ;;
            updateJson=*) [ -n "$update_url" ] && echo "updateJson=$update_url" ;;
            *) echo "$line" ;;
        esac
    done <"$file" >"$tmp"
    if [ -n "$update_url" ] && ! grep -q '^updateJson=' "$tmp"; then
        echo "updateJson=$update_url" >>"$tmp"
    fi
    mv "$tmp" "$file"
}

mkdir -p "$OUT_DIR"
PACKAGES=()

# 暂存目录放在 out/ 下：同文件系统、路径可控，构建失败也不会留下 /tmp 垃圾。
STAGE_ROOT="$OUT_DIR/.stage"

# 有 zip 就用 zip，没有就退回 Python 版（Windows 的 Git Bash 一般没有 zip）。
PYTHON_BIN=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
        PYTHON_BIN="$candidate"
        break
    fi
done

make_zip() {
    local src="$1" dst="$2"
    if command -v zip >/dev/null 2>&1; then
        (cd "$src" && zip -qr "$dst" .)
    elif [ -n "$PYTHON_BIN" ]; then
        MKZIP_EXEC_LIST="${EXEC_LIST:-}" \
            "$PYTHON_BIN" "$PROJECT_DIR/tools/mkzip.py" "$src" "$dst" >/dev/null
    else
        echo "ERROR: 找不到 zip 或 python，无法打包" >&2
        return 1
    fi
}

for VARIANT in "${VARIANTS[@]}"; do
    variant_metadata "$VARIANT"

    for ABI in "${ABIS[@]}"; do
        if [ ! -f "$PROJECT_DIR/bin/$ABI/$BINARY" ]; then
            echo "ERROR: 缺少 bin/$ABI/$BINARY，先跑 fetch.sh" >&2
            exit 1
        fi

        STAGE_DIR="$STAGE_ROOT/$VARIANT-$ABI"
        rm -rf "$STAGE_DIR" || true
        mkdir -p "$STAGE_DIR"

        # 模块根目录的公共文件
        for path in "${COMMON_FILES[@]}"; do
            cp -a "$PROJECT_DIR/$path" "$STAGE_DIR/"
        done
        chmod 755 "$STAGE_DIR/META-INF/com/google/android/update-binary"
        chmod 755 "$STAGE_DIR/customize.sh" "$STAGE_DIR/uninstall.sh" "$STAGE_DIR/action.sh"

        # 服务目录：安装器会把它整体合并进 /data/adb/runsvdir/service/aria2
        mkdir -p "$STAGE_DIR/service/aria2/log" "$STAGE_DIR/service/aria2/defaults"
        cp -a "$PROJECT_DIR/service/common/finish" "$STAGE_DIR/service/aria2/finish"
        cp -a "$PROJECT_DIR/service/common/log/run" "$STAGE_DIR/service/aria2/log/run"
        cp -a "$PROJECT_DIR/service/common/aria2.conf" "$STAGE_DIR/service/aria2/defaults/aria2.conf"
        cp -a "$PROJECT_DIR/service/$VARIANT/run" "$STAGE_DIR/service/aria2/run"
        cp -a "$PROJECT_DIR/service/$VARIANT/conf" "$STAGE_DIR/service/aria2/conf"
        chmod 755 "$STAGE_DIR/service/aria2/run" \
            "$STAGE_DIR/service/aria2/finish" \
            "$STAGE_DIR/service/aria2/log/run"
        chmod 644 "$STAGE_DIR/service/aria2/conf" "$STAGE_DIR/service/aria2/defaults/aria2.conf"

        # musl 构建（非 arm64）没有系统解析器，默认塞一组 DNS，否则开箱就解析不了域名。
        if [ "$ABI" != "arm64-v8a" ]; then
            sed -i "s|^DNS_SERVERS=.*|DNS_SERVERS=\"$MUSL_DNS_DEFAULT\"|" \
                "$STAGE_DIR/service/aria2/conf"
        fi

        # mount 把二进制作为模块的 system 负载交给管理器挂载；
        # nomount 直接放在服务目录里，随普通文件一起被合并更新。
        if [ "$VARIANT" = "mount" ]; then
            mkdir -p "$STAGE_DIR/system/bin"
            cp -a "$PROJECT_DIR/bin/$ABI/$BINARY" "$STAGE_DIR/system/bin/"
            chmod 755 "$STAGE_DIR/system/bin/$BINARY"
        else
            mkdir -p "$STAGE_DIR/service/aria2/bin"
            cp -a "$PROJECT_DIR/bin/$ABI/$BINARY" "$STAGE_DIR/service/aria2/bin/"
            chmod 755 "$STAGE_DIR/service/aria2/bin/$BINARY"
        fi

        update_url=""
        [ -n "$UPDATE_BASE" ] && update_url="$UPDATE_BASE/update/$VARIANT/$ABI.json"
        stamp_module_prop "$STAGE_DIR/module.prop" "$update_url" "$VARIANT_NAME" "$VARIANT_DESC"

        {
            echo "moduleVersion=$MODULE_VERSION"
            echo "moduleVersionCode=$MODULE_VERSION_CODE"
            echo "moduleVariant=$VARIANT"
            echo "targetAbi=$ABI"
            [ ! -f "$OUT_DIR/upstream-versions.env" ] || cat "$OUT_DIR/upstream-versions.env"
        } >"$STAGE_DIR/build-info.prop"

        # mkzip.py 在 Windows 上看不到执行位，把上面 chmod 过的路径写成清单传过去。
        EXEC_LIST="$STAGE_ROOT/.exec-$VARIANT-$ABI"
        {
            echo customize.sh
            echo uninstall.sh
            echo action.sh
            echo META-INF/com/google/android/update-binary
            echo service/aria2/run
            echo service/aria2/finish
            echo service/aria2/log/run
            if [ "$VARIANT" = "mount" ]; then
                echo system/bin/$BINARY
            else
                echo service/aria2/bin/$BINARY
            fi
        } >"$EXEC_LIST"

        ZIP_NAME="${NAME}-${MODULE_VERSION}-${VARIANT}-${ABI}.zip"
        ZIP_PATH="$OUT_DIR/$ZIP_NAME"
        rm -f "$ZIP_PATH"
        make_zip "$STAGE_DIR" "$ZIP_PATH"
        PACKAGES+=("$ZIP_NAME")

        rm -rf "$STAGE_DIR" "$EXEC_LIST" 2>/dev/null || true
        echo "=> out/$ZIP_NAME ($(du -h "$ZIP_PATH" | cut -f1))"
    done
done

{
    echo "MODULE_VERSION=$MODULE_VERSION"
    echo "MODULE_VERSION_CODE=$MODULE_VERSION_CODE"
    echo "ARIA2_VERSION=$ARIA2_VERSION"
} >"$OUT_DIR/build.env"

(cd "$OUT_DIR" && sha256sum "${PACKAGES[@]}" >SHA256SUMS)
rmdir "$STAGE_ROOT" 2>/dev/null || true
echo "=> out/SHA256SUMS"
