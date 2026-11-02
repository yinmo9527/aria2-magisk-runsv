#!/usr/bin/env python3
"""没有 `zip` 命令时（比如 Windows 的 Git Bash）用来打模块包的小工具。

用法：
    python tools/mkzip.py <源目录> <输出.zip>

和 `cd <源目录> && zip -qr <输出.zip> .` 等价：保留相对路径、按 deflate 压缩，
并且把 Unix 权限位写进 ZIP 的 external_attr，可执行文件不会在刷机后丢 755。

脚本自己会调 package.sh 里的权限已经设好，这里只负责如实搬运。
"""

import os
import stat
import sys
import zipfile


def load_exec_list():
    """读取 MKZIP_EXEC_LIST 指定的文件，得到“必须是 0755”的相对路径集合。

    Windows 上 os.stat 看不到执行位，Git Bash 的 chmod 也基本是空操作，
    所以打包脚本会把自己 chmod 过的路径写成清单传进来，这里照着用。
    """
    path = os.environ.get("MKZIP_EXEC_LIST")
    if not path or not os.path.exists(path):
        return set()
    with open(path, encoding="utf-8") as fh:
        return {line.strip() for line in fh if line.strip()}


def collect(root):
    """按名字排序返回 [(绝对路径, 相对路径, 是否为目录)]。"""
    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir != ".":
            entries.append((dirpath, rel_dir.replace(os.sep, "/"), True))
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            entries.append((full, rel, False))
    return entries


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip())

    src, dst = sys.argv[1], sys.argv[2]
    if not os.path.isdir(src):
        sys.exit("错误: %s 不是目录" % src)

    execs = load_exec_list()

    out_dir = os.path.dirname(os.path.abspath(dst))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    if os.path.exists(dst):
        os.remove(dst)

    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for full, rel, is_dir in collect(src):
            if is_dir:
                info = zipfile.ZipInfo(rel + "/")
                info.external_attr = ((stat.S_IFDIR | 0o755) << 16) | 0x10
            else:
                info = zipfile.ZipInfo(rel)
                mode = os.stat(full).st_mode
                executable = rel in execs or bool(mode & stat.S_IXUSR)
                info.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3  # 3 = Unix，解压时才会看 external_attr
            if is_dir:
                zf.writestr(info, b"")
            else:
                with open(full, "rb") as fh:
                    zf.writestr(info, fh.read())

    size = os.path.getsize(dst)
    print("=> %s (%d KiB)" % (dst, size // 1024))


if __name__ == "__main__":
    main()
