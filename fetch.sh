#!/usr/bin/env bash
#
# 抓取各架构的 aria2c 到 bin/<abi>/，并写出 out/upstream-versions.env。
#
# 二进制来源：
#   arm64-v8a    aria2 官方 Android 构建（NDK + bionic，openssl/c-ares/libssh2/
#                expat/zlib 全部静态链接，只依赖系统自带的 libc/libm/libdl）
#   其它三个架构  abcfy2/aria2-static-build 的 musl 全静态构建（无 PT_INTERP）
#
# 用法：
#   ./fetch.sh                 # 取上游最新版本
#   ./fetch.sh 1.37.0          # 固定版本
#   ./fetch.sh auto arm64-v8a  # 只取某个架构
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$PROJECT_DIR/bin"
OUT_DIR="$PROJECT_DIR/out"

ARIA2_REPO="aria2/aria2"
MUSL_REPO="abcfy2/aria2-static-build"
SUPPORTED_ABIS=(arm64-v8a armeabi-v7a x86_64 x86)

REQUESTED="${1:-auto}"
shift || true

usage() {
    cat <<EOF
用法: $0 [auto|VERSION] [ABI...]

  auto        取 aria2 上游最新 release（默认）
  VERSION     固定版本，例如 1.37.0

  ABI         可只构建部分架构：${SUPPORTED_ABIS[*]}

例:
  $0
  $0 1.37.0
  $0 auto arm64-v8a
EOF
}

if [ "$REQUESTED" = "-h" ] || [ "$REQUESTED" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -gt 0 ]; then
    ABIS=("$@")
else
    ABIS=("${SUPPORTED_ABIS[@]}")
fi

for abi in "${ABIS[@]}"; do
    ok=0
    for s in "${SUPPORTED_ABIS[@]}"; do
        [ "$abi" = "$s" ] && ok=1
    done
    if [ "$ok" -ne 1 ]; then
        echo "ERROR: 不支持的架构: $abi" >&2
        usage >&2
        exit 1
    fi
done

# GitHub API 的小封装。--http1.1 + 重试：releases 文档较大，CI 上偶发 HTTP/2 流被掐。
api() {
    curl -fsSL --http1.1 --retry 3 --retry-delay 2 --retry-all-errors \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$1"
}

# 从 API 响应里抠 tag_name，避免依赖 jq（Windows 的 Git Bash 上通常没有）。
tag_name_of() {
    sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

resolve_version() {
    case "$REQUESTED" in
        auto)
            local tag
            tag="$(api "$ARIA2_REPO/releases/latest" | tag_name_of)"
            [ -n "$tag" ] || { echo "ERROR: 无法从 GitHub API 取到 aria2 最新版本" >&2; exit 1; }
            VERSION="${tag#release-}"
            ;;
        v[0-9]* | release-*)
            VERSION="${REQUESTED#release-}"
            VERSION="${VERSION#v}"
            ;;
        [0-9]*)
            VERSION="$REQUESTED"
            ;;
        *)
            echo "ERROR: 无法识别的版本参数: $REQUESTED" >&2
            usage >&2
            exit 1
            ;;
    esac
}

# 校验下载到的 ELF 架构，防止上游改命名导致把错架构塞进包里。
# EI_CLASS 在偏移 4（1=32 位，2=64 位），e_machine 在偏移 18（小端两字节）。
elf_check() {
    local abi="$1" file="$2" want_class want_machine cls lo hi mach
    case "$abi" in
        arm64-v8a) want_class=2; want_machine=183 ;;
        armeabi-v7a) want_class=1; want_machine=40 ;;
        x86_64) want_class=2; want_machine=62 ;;
        x86) want_class=1; want_machine=3 ;;
    esac

    if [ ! -f "$file" ]; then
        echo "ERROR: $abi 的 aria2c 没有下载成功" >&2
        return 1
    fi

    cls="$(od -An -tu1 -j4 -N1 "$file" | tr -d ' \n')"
    lo="$(od -An -tu1 -j18 -N1 "$file" | tr -d ' \n')"
    hi="$(od -An -tu1 -j19 -N1 "$file" | tr -d ' \n')"
    mach=$((lo + hi * 256))

    if [ "$cls" != "$want_class" ] || [ "$mach" != "$want_machine" ]; then
        echo "ERROR: $abi 的 ELF 头不匹配（class=$cls machine=$mach，期望 $want_class/$want_machine）" >&2
        return 1
    fi
    echo "   ok: $abi ELF class=$cls machine=$mach"
}

resolve_version
echo "=> aria2: $VERSION"

mkdir -p "$BIN_DIR" "$OUT_DIR"

# 临时目录放在 out/ 下：和产物同一个文件系统，不依赖 /tmp 的权限和路径风格。
TMP_DIR="$OUT_DIR/.fetch-tmp"
rm -rf "$TMP_DIR" || true
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT

for ABI in "${ABIS[@]}"; do
    case "$ABI" in
        arm64-v8a)
            URL="https://github.com/$ARIA2_REPO/releases/download/release-${VERSION}/aria2-${VERSION}-aarch64-linux-android-build1.zip"
            SOURCE="aria2-official-android"
            ;;
        armeabi-v7a)
            URL="https://github.com/$MUSL_REPO/releases/download/${VERSION}/aria2-armv7-linux-musleabihf_static.zip"
            SOURCE="abcfy2-musl-static"
            ;;
        x86_64)
            URL="https://github.com/$MUSL_REPO/releases/download/${VERSION}/aria2-x86_64-linux-musl_static.zip"
            SOURCE="abcfy2-musl-static"
            ;;
        x86)
            URL="https://github.com/$MUSL_REPO/releases/download/${VERSION}/aria2-i686-linux-musl_static.zip"
            SOURCE="abcfy2-musl-static"
            ;;
    esac

    ZIP="$TMP_DIR/$ABI.zip"
    echo "   Downloading $ABI <- $URL"
    if ! curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o "$ZIP" "$URL"; then
        echo "ERROR: 下载失败: $URL" >&2
        echo "       上游可能没有 $VERSION 的 $ABI 构建，用更早的版本或换架构试试" >&2
        exit 1
    fi

    rm -rf "$TMP_DIR/$ABI"
    mkdir -p "$TMP_DIR/$ABI"
    unzip -q -o "$ZIP" -d "$TMP_DIR/$ABI"

    mkdir -p "$BIN_DIR/$ABI"
    SRC="$(find "$TMP_DIR/$ABI" -type f -name aria2c | head -n 1)"
    if [ -z "$SRC" ]; then
        echo "ERROR: $ABI 的压缩包里没有 aria2c" >&2
        exit 1
    fi
    cp -f "$SRC" "$BIN_DIR/$ABI/aria2c"
    chmod 755 "$BIN_DIR/$ABI/aria2c"
    printf '%s\n' "$SOURCE" > "$BIN_DIR/$ABI/SOURCE"

    elf_check "$ABI" "$BIN_DIR/$ABI/aria2c"
    echo "   ok: bin/$ABI/aria2c ($(du -h "$BIN_DIR/$ABI/aria2c" | cut -f1), $SOURCE)"
done

cat > "$OUT_DIR/upstream-versions.env" <<EOF
ARIA2_VERSION=$VERSION
ARIA2_TAG=release-$VERSION
ARIA2_SOURCE_ARM64=aria2-official-android
ARIA2_SOURCE_OTHERS=abcfy2-musl-static
EOF

echo ""
echo "=> 模块版本由 package.sh 用 revision 文件拼出"
echo "=> Wrote out/upstream-versions.env"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "aria2_version=$VERSION" >> "$GITHUB_OUTPUT"
fi
