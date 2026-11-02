# aria2-magisk-runsv

[aria2](https://aria2.github.io) packaged as a **[runsvdir-magisk](https://github.com/sorubedo/runsvdir-magisk)** service: started at boot by `runsvdir`, restarted when it dies, logged by `svlogd`, with the RPC endpoint always available for AriaNg or any aria2 client.

[中文说明](README_zh-CN.md)

---

## What this is

`runsvdir-magisk` installs the runit tools and starts `runsvdir` at boot; service definitions are left to the user. This module supplies the aria2 side of that contract — service definition, binary, installer and updater — and follows the same layout as [openlist-magisk-runsv](https://github.com/sorubedo/openlist-magisk-runsv):

- **No reinvention**: supervision, boot start and log collection belong to runsvdir-magisk. There is no daemon script in this module.
- **Two variants** (see below), which exist to answer one practical question: who should own the downloaded files?
- **Self-contained binary**: no Termux, no other module, no shared libraries to juggle.
- **Layered config**: `conf` decides *how to launch* (port, user, directories); `aria2.conf` is aria2's own config file with the exact option names from the manual.

## Features

- Boot start; runsv restarts the process within a second if it exits
- Session persistence via `--save-session` + `--input-file`, unfinished downloads survive reboots
- RPC on `6800`, random token generated on first install
- CA bundle generated from the Android trust store, so HTTPS works out of the box (the statically linked OpenSSL has no idea where Android keeps certificates)
- Downloads owned by `shell` (uid 2000) in the mount variant — same as `adb push`, so file managers, MTP and gallery apps can rename/delete them
- Log rotation: 10 MiB × 5 files
- Volume-key action menu in the module card: start/stop, autostart toggle, show RPC credentials, rebuild CA bundle
- 4 ABIs × 2 variants, CI tracks the upstream aria2 release

## Requirements

| Requirement | Notes |
| --- | --- |
| Rooted Android | Magisk 20.4+, KernelSU or APatch |
| [runsvdir-magisk](https://github.com/sorubedo/runsvdir-magisk) | **Required.** Provides `runsvdir`, `sv`, `chpst`, `svlogd` and `/data/adb/runsvdir/service/` |
| KSU/APatch/Magisk 27+ | Only for the action menu; older managers just hide it |

The installer aborts if the runsvdir module is missing or disabled.

## Which ZIP

Variants first:

| | **mount** (recommended) | **nomount** |
| --- | --- | --- |
| Binary | mounted at `/system/bin/aria2c` | `bin/aria2c` inside the service dir |
| Runs as | `shell` (uid 2000) + storage groups | `root` |
| State dir | `/storage/emulated/0/Android/aria2` | `data/` in the service dir |
| Download dir | `/storage/emulated/0/Download/aria2` | `downloads/` in the service dir |
| File ownership | `shell`, editable by any file manager | `root`, read-only for most apps |
| Touches `/system` | yes (one read-only mount point) | no |
| Best for | phone downloads you want to play/share immediately | headless use, no `/system` changes, arbitrary target paths |

Then the ABI:

| ABI | Source | Notes |
| --- | --- | --- |
| `arm64-v8a` | official aria2 Android build | NDK + bionic; openssl/c-ares/libssh2/expat/zlib statically linked, only libc/libm/libdl come from the system |
| `armeabi-v7a` | [abcfy2/aria2-static-build](https://github.com/abcfy2/aria2-static-build) | fully static musl |
| `x86_64` / `x86` | same | fully static musl |

> **musl ABIs**: musl cannot read Android's DNS configuration (there is no `/etc/resolv.conf`), so those packages ship `DNS_SERVERS="223.5.5.5,119.29.29.29"` in `conf` and pass it through `--async-dns-server`. Change that line if you prefer other resolvers. arm64 uses the system resolver and leaves it empty.

Check your ABI with `getprop ro.product.cpu.abi`.

## Install

1. Install **runsvdir-magisk**, reboot, confirm `/data/adb/runsvdir/service/` exists.
2. Flash the ZIP matching your variant and ABI.
3. Reboot. (Mandatory for mount — the binary is a mount. The nomount variant usually comes up within seconds.)
4. Verify:

```sh
sv status /data/adb/runsvdir/service/aria2
# run: /data/adb/runsvdir/service/aria2: (pid 12345) 12s
```

## Layout

**mount variant**

```
/data/adb/runsvdir/service/aria2/       # service definition, root-owned
├── run                                 # launch script (sv restart after edits)
├── conf                                # port / user / directories
├── finish                              # exit hook (no-op by default)
├── rpc-secret                          # generated token, never overwritten by updates
├── defaults/aria2.conf                 # default aria2 config template
└── log/run                             # log sub-service

/storage/emulated/0/Android/aria2/      # runtime state, shell-owned
├── aria2.conf                          # seeded from defaults/, edit freely
├── session/aria2.session
├── dht/dht.dat
└── ca/cacert.pem                       # CA bundle built from the system store

/storage/emulated/0/Download/aria2/     # downloads
/data/adb/runsvdir/log/sv/aria2/current # logs
```

The **nomount variant** keeps a single tree under the service dir, with `bin/`, `data/` and `downloads/`.

## Configuration

### `conf` — how to launch

| Variable | Default (mount / nomount) | Meaning |
| --- | --- | --- |
| `DATA_DIR` | `/storage/.../Android/aria2` / `./data` | state directory |
| `DOWNLOAD_DIR` | `/storage/.../Download/aria2` / `./downloads` | aria2 `--dir` |
| `RUN_AS` | `:2000:2000:1028:1015:1023:1078` / `""` | chpst numeric spec; empty means root |
| `BIN` | `/system/bin/aria2c` / `./bin/aria2c` | aria2 binary |
| `RPC_PORT` | `6800` | RPC port |
| `RPC_LISTEN_ALL` | `1` | `1` all interfaces, `0` loopback only |
| `RPC_SECRET` | `""` | empty = use the `rpc-secret` file |
| `DNS_SERVERS` | `""` (set for non-arm64 builds) | explicit resolvers for musl builds |
| `EXTRA_ARGS` | `""` | extra argv, space separated |
| `WAIT_DECRYPT` | `1` / `0` | wait for `/sdcard` to be decrypted |

The numeric form avoids `/etc/passwd` and `/etc/group` lookups entirely, which is why it is used instead of names: `2000` shell, `1028` sdcard_r, `1015` sdcard_rw, `1023` media_rw, `1078` external_storage.

### `aria2.conf` — aria2 itself

A plain aria2 config file; `sv restart` to apply. Defaults are tuned for phones (`file-allocation=none`, `disk-cache=64M`, `split=8`); tracker and user-agent examples are commented out.

`dir`, `enable-rpc`, `rpc-secret`, `input-file`, `ca-certificate` are passed on the command line by `run`, and **command line beats the config file** — setting them here has no effect.

To reset: delete `DATA_DIR/aria2.conf` and restart the service; it is re-seeded from `defaults/`.

## Connecting AriaNg

1. In the action menu pick **显示 RPC 地址与密钥**, or:

```sh
cat /data/adb/runsvdir/service/aria2/rpc-secret
ip route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p'
```

2. Open [AriaNg](https://ariang.mayswind.net/) (or AriaNg Native / a self-hosted copy) → **Settings → RPC**:

- address `http://<phone-ip>:6800/jsonrpc`
- secret: the token above

> An https AriaNg page cannot talk to an http RPC endpoint (mixed content). Use the app, a local copy, or `127.0.0.1` on-device.

With `RPC_LISTEN_ALL=1` anyone on the LAN can see the port; the token is the only gate. Set it to `0` on public Wi-Fi.

## Commands

```sh
SVC=/data/adb/runsvdir/service/aria2

sv status $SVC          # status
sv up $SVC              # start (this session only)
sv down $SVC            # stop (this session only)
sv restart $SVC         # restart, use after editing conf / aria2.conf

touch $SVC/down         # disable autostart
rm $SVC/down            # enable autostart

sv-enable aria2         # start + enable (needs SVDIR)
sv-disable aria2        # stop + disable

tail -f /data/adb/runsvdir/log/sv/aria2/current
```

`sv-enable` / `sv-disable` read `SVDIR` (runsvdir-magisk convention): `export SVDIR=/data/adb/runsvdir/service` first.

## Action menu

Magisk 27+ / KernelSU / APatch expose an action button on the module card:

- **Volume Down** next entry, **Volume Up** run it
- status, start/stop/restart, autostart toggle, show RPC credentials, rebuild CA bundle, aria2 version

After a system upgrade that rotates the trust store, hit **rebuild CA bundle** — no reflash needed.

## Troubleshooting

**Installer aborts: runsvdir-magisk missing** — install it and reboot first; the check looks at `/data/adb/modules/runsvdir` plus its `disable`/`remove` markers.

**`sv status` keeps showing `1s`, log says `/system/bin/aria2c` not found** — the mount variant needs a reboot after install/update for the mount to take effect.

**HTTPS fails with a certificate error** — check that `DATA_DIR/ca/cacert.pem` is non-empty; rebuild it from the action menu, or drop your own PEM bundle there.

**DNS failures** — arm64 uses the system resolver; other ABIs need `DNS_SERVERS` set in `conf`.

**Downloaded files cannot be deleted from a file manager** — you are on the nomount variant (root-owned). Switch to mount, or set `RUN_AS=":2000:2000:1028:1015:1023:1078"`.

**RPC unreachable** — service running? `RPC_LISTEN_ALL=1`? same subnet, no AP isolation? secret correct?

**Port 6800 / 51413 busy** — change `RPC_PORT` in `conf`, `listen-port` / `dht-listen-port` in `aria2.conf`.

**What does an update replace?** The default "binary only" mode replaces `aria2c` and keeps `run`/`conf`/`aria2.conf`. "Full update" also overwrites `run`/`conf` from the package, but never touches `aria2.conf` (in the data dir), sessions, downloads or `rpc-secret`.

**After uninstall** — the service directory is removed. The mount variant's `/storage/emulated/0/Android/aria2` and `Download/aria2` are user data and stay behind on purpose, so a reinstall picks up where you left off.

## Building

### GitHub Actions

- `Build` — manual, artifacts only, optional aria2 version
- `Build and Release` — on tag `v1.37.0-r1` or manual: builds all 8 ZIPs, publishes a release, commits `update/<variant>/<abi>.json` back to the default branch

This repository targets `yinmo9527/aria2-magisk-runsv`:

- `author` in `module.prop` is already `yinmo9527`
- on release the workflow sets `UPDATE_BASE` to `https://raw.githubusercontent.com/yinmo9527/aria2-magisk-runsv/main`

If you fork it or rename the repo, update those two. Local builds that do not pass `UPDATE_BASE` simply skip
`updateJson` and work fine.

One convention to keep: bump the `revision` file whenever module scripts change — the version is
`<aria2 version>-r<revision>` and `versionCode` is derived from it, so without a bump the manager will not see an update.

### Locally

```sh
./fetch.sh                 # fetch aria2c for the 4 ABIs into bin/
./package.sh               # write out/*.zip + SHA256SUMS
./package.sh arm64-v8a     # one ABI only
```

Needs `bash`, `curl`, `unzip` and `zip`; on Windows Git Bash (no `zip`) the script falls back to `tools/mkzip.py` (Python 3).

## License

**This repository's code (scripts, installer, packaging) is MIT**, see [LICENSE](LICENSE).

**The bundled `aria2c` is not MIT** — it is GPL-2.0-or-later. Where to get its source is documented in
[docs/aria2-SOURCE.md](docs/aria2-SOURCE.md). The two are separate works shipped on the same medium (the scripts
`exec` the binary; nothing is linked into a single program), which is the "mere aggregation" case of GPLv2 §2, so
MIT does not get pulled into GPL. Just do not describe the ZIP as "MIT-licensed software" as a whole.

- aria2 license text: [docs/aria2-COPYING](docs/aria2-COPYING)
- Upstream Android build notes: [docs/aria2-README.android](docs/aria2-README.android)
- OpenSSL 1.1.1k statically linked into the binary: [docs/aria2-LICENSE.OpenSSL](docs/aria2-LICENSE.OpenSSL)
- runit binaries (`runsvdir`/`sv`/`chpst`/`svlogd`) are **not** shipped here; they come from
  [runsvdir-magisk](https://github.com/sorubedo/runsvdir-magisk), BSD 3-Clause

## Credits

- [sorubedo/runsvdir-magisk](https://github.com/sorubedo/runsvdir-magisk) — runit runtime and service directory convention
- [sorubedo/openlist-magisk-runsv](https://github.com/sorubedo/openlist-magisk-runsv) — the two-variant design, installer and packaging flow this module is modelled on
- [aria2/aria2](https://github.com/aria2/aria2), [abcfy2/aria2-static-build](https://github.com/abcfy2/aria2-static-build) — binaries
