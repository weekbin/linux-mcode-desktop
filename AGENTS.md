# AGENTS.md — 给 AI Agent 看的操作指南

> 接手这个 repo 的 agent，请从头读这份文档。**目标**：把 `MiniMax Code`
> Windows NSIS 安装包 (`@mmx-agent/electron v3.0.67-inside.44`) 转成可在
> Ubuntu 24.04+ 上运行的 Linux GUI 客户端。

---

## 1. 仓库结构

```
linux-mcode-desktop/
├── inputs/                  # 用户放 .exe 的目录 (gitignored, README 留路径)
│   └── README.md
├── scripts/
│   ├── build-linux-gui.sh   # 核心: NSIS 解包 → asar 抽 → 注入 Linux native → patch JS → repack
│   ├── build-deb.sh         # 把 unpacked/ 打成 .deb
│   ├── build-targz.sh       # 打包 .tar.gz (可移植版本)
│   ├── build-all.sh         # 编排: build-linux-gui + build-deb + build-targz
│   ├── install-protocol-handler.sh  # dev 模式注册 minimax[-cn]:// OAuth callback
│   └── run-mmx-linux.sh     # 装好后启动客户端
├── src/
│   ├── libmmmx-shim.c       # 提供 fmod@GLIBC_2.38 的 shim
│   ├── libmmmx-shim.map     # linker version script
│   ├── build-shim.sh        # 编译 shim
│   └── better-sqlite3-binding.gyp.patch  # 给 better-sqlite3 加 -lmmmx 的 patch
├── lib/                     # 预编译的 native shim (committed, 14KB)
│   └── libfmod_shim.so      # fmod@GLIBC_2.38 fallback, 让 fresh clone 不需要 gcc 也能 build-deb
├── tools/                   # 验证工具 (双路径)
│   ├── test-ubuntu.sh       # 路径 B: docker headless 冒烟 (CI / 日常)
│   ├── test-real-machine.sh # 路径 A: 真机/桌面 runtime 验证 (release 前必跑)
│   └── lib/
│       ├── matrix.json      # 版本支持矩阵单源数据
│       ├── matrix.sh        # bash 接口: matrix_codename / matrix_image / matrix_expected
│       └── parse-log.sh     # 从 log 抽 status: parse_log_status <log> <scope>
├── docs/
│   └── PIPELINE.md          # 完整 exe→deb 流程 (Mac/Ubuntu side-by-side, input/output 约定, 已知坑)
├── unpacked/                # NSIS 解包输出 (gitignored, 由 build-linux-gui.sh 生成)
│   └── app-64/              #   ~1.6GB, 永远不 commit
├── dist/                    # deb 产物 (gitignored, 由 build-deb.sh 生成)
├── README.md
├── README-LINUX.md
├── AGENTS.md                # 你正在读
└── .gitignore
```

**绝对不要** commit 进仓库的东西（看 `.gitignore`）：
- `MiniMax Inside Code Setup *.exe` (Windows 安装包 ~1GB)
- `unpacked/app-64/` (解包后的 Windows 内容 ~880MB)
- `unpacked/app-64/resources/app.asar` 和 `app.asar.orig` (改好的 asar 440MB+)
- `dist/*.deb` `dist/*.tar.gz` `dist/*.tar` (产物)
- `node_modules/` `__pycache__/` `*.pyc`
- `/tmp/mmx-*` `/tmp/mmx-linux-install/` 等构建临时目录

---

## 2. 输入与输出

**输入**：
- `MiniMax Inside Code Setup 3.0.67-inside.44.exe` — 用户给（不存仓库）
- Linux Electron 43.1.0 — 任何位置都行，通过 `ELEC43_DIR` 环境变量指

**输出**（在 `dist/`）：
- `minimax-code_3.0.67-inside.44_amd64.deb` (~227MB) — 主力分发包
- `minimax-code_3.0.67-inside.44_linux-x64.tar.gz` (~337MB) — 免 root 部署
- `minimax-code_3.0.67-inside.44_linux-x64.tar` (~1.3GB) — 含 debug 符号的完整包

---

## 3. 完整 pipeline 详解

### 3.1 `scripts/build-linux-gui.sh` — asar 重打包

**职责**：
1. 用 7z/nsis 把 Windows `.exe` 解到 `unpacked/app-64/`
2. 用 `@electron/asar` (4.3.0，**有 bug** — `extract-file` 不可用，但 `list` OK)
   把 `unpacked/app-64/resources/app.asar` 抽到 `/tmp/mmx-app-v3/`
3. 注入 4 个 Linux native binding 替代 Windows DLL：
   - `better-sqlite3` v12.10.1 (从 source rebuild 给 electron 43 NMV 148)
   - `node-pty` v1.0.0 (rebuild for electron 43)
   - `@nut-tree/libnut-linux` (N-API binary, ABI 稳定)
   - `@vscode/ripgrep-linux-x64`
4. Patch asar 内的 JS (typebox 兼容 / GPU disable / open-external / tray / deeplink / mcode-tools)
5. 用 `asar pack` 重新打包到 `unpacked/app-64/resources/app.asar`

**关键 patch**（在 patch_js 函数里）：
- `dist/main/index.js`: `app.disableHardwareAcceleration()` + `disable-gpu` + `in-process-gpu`
- `dist/main/ipc/window.ipc.js`: `OPEN_EXTERNAL` handler 改用 xdg-mime + .desktop Exec= parser (避免 hardcode Chrome 路径)
- `dist/main/modules/tray/index.js`: Linux 跳过 tray
- `dist/main/modules/deeplink/index.js`: 静默注册 protocol
- `dist/main/modules/local-runtime/native-sqlite-env.js`: prebuild-install 缺失时降级
- `dist/main/modules/mcode-tools/index.js`: 降级 warning

**已知坑**：
- `@electron/asar@4.3.0` 的 `extract-file` 命令在某些 asar (含 SHA256 block) 上
  报 "was not found in this archive" 但 list 工作。**用 asar 3.2.10** 或 **写 Python 解析器**
  抽 pi-ai / pi-tui / pi-coding-agent (这些包 npm latest 删了 TUI export，
  0.79.1 才有，**版本号要严格匹配 asar.orig**)。
- 抽完 asar.orig 后，`/tmp/mmx-app-v3/node_modules/@earendil-works/` 下可能只有
  `pi-agent-core` / `pi-ai` / `pi-coding-agent`，缺 `pi-tui`。**手动从 npm 装 0.79.1 后 cp 进去**。

### 3.2 `scripts/build-deb.sh` — 打 .deb

**关键步骤**：
1. 复制 `unpacked/app-64/resources/app.asar.unpacked/` 的 Linux natives
2. 把 `libfmod_shim.so` 复制到 `PKG_ROOT/opt/MiniMax Code/`
3. 生成 `run.sh` (用 `LD_PRELOAD` 加载 shim，路径含空格处理过)
4. 生成 `DEBIAN/preinst` (用 `apt-get install -f -y` 自动补依赖)
5. 用 `dpkg-deb --build` (不 fakeroot，避免 zstd checksum bug) 打包

**NEEDED 列表** (看 control 文件) 涵盖 electron 43 通用 Linux 需求 + 这个项目特有的
`libappindicator3-1` (tray 可选)。

**已知坑**：
- `dpkg-deb --build` 跑 1.3GB 慢，**CPU 持续 1500%+** 是正常的（zstd 多核压缩），等 5-10 分钟
- build-deb.sh 里有 `find ... | xargs touch -d` 在 1.3GB 上**巨慢**（5+ 分钟），
  必要时直接 `dpkg-deb --build` 跳过这步
- `LD_PRELOAD` 路径含空格必须 quote 或 `cp` 到 `/tmp/minimax-fmod-shim.so`

### 3.3 `scripts/build-targz.sh` / `scripts/build-all.sh`

简单 wrapper，打包不同格式。

---

## 4. 关键 patches (per-system)

### 4.1 libmmmx shim (`src/libmmmx-shim.c`)

**问题**：`better-sqlite3.node` 在 noble (GLIBC 2.39) rebuild 后引用 `fmod@GLIBC_2.38`，
老系统 libm 没有这个 symbol。

**shim 原理**：
- 导出 `fmod@GLIBC_2.38` 和 `fmod@GLIBC_2.2.5` 两个 versioned symbol
- C99 fmod 实现（不用 `__builtin_fmod` 避免被 GLIBC 2.38 builtin 替换）
- build 完后 `nm -D libmmmx.so | grep fmod` 看到两行带 versioned symbol

**build**：
```bash
cd src && ./build-shim.sh
# 输出 libmmmx.so (装到 /opt/mmx-shared/)
```

**部署**：在 `debian/control` postinst 或 `build-deb.sh` 里 cp 到 `/opt/mmx-shared/libmmmx.so`

### 4.2 better-sqlite3 binding.gyp patch (`src/better-sqlite3-binding.gyp.patch`)

`ldflags` 加：
```python
'-Wl,-rpath,/opt/mmx-shared',
'-L/opt/mmx-shared',
'-lmmmx',
```

应用：
```bash
cd node_modules/better-sqlite3
patch -p0 < /path/to/better-sqlite3-binding.gyp.patch
# 然后 electron-rebuild
node_modules/.bin/electron-rebuild -v 43.1.0 -e $ELEC43_DIR -f -w better-sqlite3
```

⚠️ 路径**不能含空格**，否则会被 split 成两个 ld args。**绝对路径** `/opt/mmx-shared` 是 no-space 选项。

### 4.3 preinst 自动依赖补 (`scripts/build-deb.sh` 里的 heredoc)

```bash
set +e  # 不要让单个错误中止整个 preinst
# 1) apt-get update
# 2) 尝试装完整 dep 列表 (有 alternates 兼容不同 Ubuntu)
# 3) 失败则 apt-get install -f -y (修复 unmet deps)
# 4) dpkg --configure -a
```

**不要只检查 `dpkg -s`** — 装的包版本太老也算 unmet dep。

---

## 5. 端到端验证 (双路径)

release 前必须两个路径都过：

| 路径 | 工具 | 范围 | 谁能跑 |
|------|------|------|--------|
| **Docker headless** (CI / smoke) | `tools/test-ubuntu.sh` | 装包 + 启动到 login + 无 GLIBC 错 | 任何人, 任意 Linux |
| **真机 desktop** (final release) | `tools/test-real-machine.sh` | 装包 + 启动 + OAuth + LocalRuntime + state.db | 真实 Ubuntu + GUI + 账号 |

**为什么两条路径**：
- headless 容器跑不到 OAuth，state.db / v2_dir 永远创建不出来
- 真机跑 CI 太重 (要 GUI + 账号)
- 两条路径共用版本支持矩阵 (`tools/lib/matrix.json`)，不会漂移

### 5.1 路径 A — 真机 / 桌面 (`tools/test-real-machine.sh`)

**真 PASS 标准**：`state.db` 创建 (即 LocalRuntimeUtility 跑完 V2 migration)

**用法**:
```bash
# 完整测 (默认 10 min timeout, 给 OAuth 留时间)
tools/test-real-machine.sh

# 只到 login 窗口 (不需要账号, 用于日常 debug)
tools/test-real-machine.sh --until-login

# 自定义 timeout + 跳过装包
tools/test-real-machine.sh --timeout 300 --skip-install
```

**前置**:
- 在目标 Ubuntu 机器上跑 (不能 docker)
- 已 build 的 `dist/minimax-code_3.0.67-inside.44_amd64.deb`
- GUI (有 DISPLAY / wayland，没有会自动 fallback Xvfb)
- 网络 + 真实账号 (OAuth 登录)

**判定 (scope=realmachine)**:
- ✅ `RUNTIME_PASS` = `state.db` 创建或 `LocalRuntimeUtility runtime ready`
- ⏸ `LOGIN_READY` = `WindowManager login registered` 但还没登录 (超时前未到 RUNTIME_PASS)
- ❌ `STARTUP_FAIL` = 装不上 / 启动不到 WindowManager
- ❌ `GLIBC_ERROR` / `MISSING_PKG` (任何路径都致命)

**真机版本支持矩阵** (来自 `tools/lib/matrix.json`):
| 版本 | 代号 | 预期 | 原因 |
|------|------|------|------|
| 20.04 | focal | FAIL | better_sqlite3 GLIBC 2.31 加载失败 (post-OAuth) |
| 22.04 | jammy | PARTIAL | better_sqlite3 fmod@GLIBC_2.38 需 libmmmx 验证 (sandbox 屏蔽 LD_PRELOAD, §6 P0) |
| 24.04 | noble | PASS | 主验证平台 |
| 25.04 | plucky | PASS | EOL, 仅供参考 |
| 25.10 | questing | PASS | 短支持周期 |
| 26.04 | resolute | PASS | 最新 LTS |

### 5.2 路径 B — Docker headless (`tools/test-ubuntu.sh`)

**headless 真 PASS 标准**：`WindowManager login registered` + 无 GLIBC/missing-pkg 错

> ⚠️ headless 容器**测不到** LocalRuntime / state.db (要 OAuth 登录)
> 容器里报 `state_db=missing` = 预期，**不是 bug**

**用法**:
```bash
# 测所有支持版本
tools/test-ubuntu.sh

# 只测某些版本
tools/test-ubuntu.sh 24.04 26.04

# 测完保留容器 (debug)
tools/test-ubuntu.sh --no-cleanup 24.04

# 自定义 deb
DEB_PATH=/path/to/deb tools/test-ubuntu.sh 24.04
```

**前置**: docker (镜像自动 pull) + 已 build 的 deb + 充足磁盘 (~2GB / 容器)

**判定 (scope=docker)**:
- ✅ `RUNTIME_PASS` = 意外之喜，state.db 真创建出来了
- ✅ `PASS` = `WindowManager login registered` + 无 GLIBC/missing-pkg 错
- ❌ `GLIBC_ERROR` / `MISSING_PKG` / `STARTUP_FAIL`

**docker 版本支持矩阵** (来自 `tools/lib/matrix.json`):
| 版本 | 预期 | 原因 |
|------|------|------|
| 20.04 focal | PASS | 装包+启动 OK (GLIBC 错只在 better_sqlite3 加载时才暴露, post-OAuth) |
| 22.04 jammy | PASS | 同上 |
| 24.04 noble | PASS | 主验证平台 |
| 25.04 plucky | PASS | EOL |
| 25.10 questing | PASS | 短支持 |
| 26.04 resolute | PASS | 最新 LTS |

> **重要**: docker scope 的 PASS 不代表真机能跑。release 前必须 §5.1 真机路径也过。

### 5.3 共享工具

- **`tools/lib/matrix.json`** — 版本支持矩阵单源数据 (glibc / gcc / 预期 / reason)
- **`tools/lib/matrix.sh`** — bash 接口: `matrix_codename` / `matrix_image` / `matrix_expected` / `matrix_get`
- **`tools/lib/parse-log.sh`** — 从 log 抽 status token: `parse_log_status <log> <scope>`

两个测试脚本都 import 这俩 lib，矩阵和判定逻辑**不会**在两个脚本里漂移。

### 5.4 手动 debug 单个版本 (docker)

```bash
# 启动一个 24.04 容器并保持运行
docker run -it --rm \
    -v /path/to/deb:/tmp/minimax.deb:ro \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -e DISPLAY=:99 \
    --name mmx-debug \
    ubuntu:24.04 bash

# 在容器内:
apt-get update && apt-get install -y libnss3 libgbm1 libxkbcommon0 xvfb
dpkg -i /tmp/minimax.deb
Xvfb :99 -screen 0 1280x800x24 &
export DISPLAY=:99
# 装 gdb / strace / ltrace 等工具调
apt-get install -y gdb strace ltrace
strace -f -e openat -o /tmp/strace.log /opt/MiniMax\ Code/run.sh
# 看 better_sqlite3 加载情况
grep -E 'better_sqlite3|libmmmx|libm' /tmp/strace.log | head -20
```

### 5.5 用 `--no-cleanup` 保留容器（推荐 docker debug 流程）

```bash
# 测 24.04 失败时, 保留容器进一步调
tools/test-ubuntu.sh --no-cleanup 24.04
# 容器名: mmxtest-noble-<pid> (会打印在 log 里)
docker ps -a | grep mmxtest
# 进容器
docker exec -it mmxtest-noble-12345 bash
# 看 runtime 写过的所有文件
find /root/.config/MiniMax-Code -type f | head -30
# 看 shim 是否加载
cat /proc/$(pgrep -f 'MiniMax Code/run.sh' | head -1)/maps | grep -E 'libmmmx|libm\.so'
# 看完整 electron log
cat /tmp/mmx.log
# 装 gdb 再跑一遍
apt-get install -y gdb strace
strace -f -e openat /opt/MiniMax\ Code/run.sh 2>&1 | grep -E 'better_sqlite3|libmmmx'
# 删容器
docker rm -f mmxtest-noble-12345
```

---

## 6. 已知未解决问题（按优先级）

### 🔴 P0: GLIBC 兼容性（20.04/22.04 真机）

**问题**：
- electron 43 chromium 内部用 GLIBC 2.38 symbols（`__libc_single_threaded`, `fmod` 等）
- noble (24.04): GLIBC 2.39 ✅
- jammy (22.04): GLIBC 2.35 ❌
- focal (20.04): GLIBC 2.31 ❌

**当前状态**：
- shim 已写好（`src/libmmmx-shim.c`），link patch 准备好（`src/better-sqlite3-binding.gyp.patch`）
- **未在 jammy/focal 真机端到端验证过 shim 链接后的 better_sqlite3.node 能否真的加载**
- shim 通过 `LD_PRELOAD` 在 main process 工作，**但被 chromium sandbox 屏蔽**（child process 不继承）
- patchelf 给 `better_sqlite3.node` 加 NEEDED 失败，因为 electron 把 `.node` 复制到
  `/tmp/.org.chromium.Chromium.<random>` 加载，patchelf 不影响副本

**下一步方案**（任选一）：
1. **A. objcopy hack** — `objcopy --redefine-syms` 改 fmod 的 versioned symbol 表
2. **B. LD_AUDIT** — 用 audit interface 强制注入到所有 child process
3. **C. 换 electron 30** — electron 30 还没用 GLIBC 2.38 的 symbols，工作量很大
4. **D. 换 WASM sqlite** — 用 `node-sqlite3-wasm`，零 native GLIBC，**唯一干净路线**，
   但要改 `@mavis/local-runtime` 代码
5. **E. 只支持 noble** — 文档化限制，jammy/focal 列为 unsupported

### 🟡 P1: OAuth scheme 不确定 (`minimax-cn` vs `minimax-code`)

**问题**: asar `getProtocolNameByEnv()` 动态返回 6 种 scheme:
`minimax` / `minimax-cn` / `minimax-test` / `minimax-cn-test` / `minimax-staging` / `minimax-cn-staging`

asar `parse.js` 正则 `^minimax(?:-cn)?(?:-test|-staging)?:$` 也接受全部 6 种。

外部 bug 报告说 web 用 `minimax-code://`, asar 跟 web 后端**都没**这个 scheme — 报告人大概率把 `minimax-code.desktop` 文件名跟 scheme 前缀搞混了.

**修法** (✅ 已修, commit `35cc206`):
- `.desktop` `MimeType` 写全部 6 种 (en/zh × prod/test/staging)
- postinst `xdg-mime default` 对全部 6 个 scheme 都设 default
- 不需要改 asar (支持 6 种已经是对的), 只让 Linux desktop 端跟 asar 一致

**验证** (用户机器 zh 线上 + 跑 fix 后):
```
x-scheme-handler/minimax → minimax-linux.desktop ✓
x-scheme-handler/minimax-cn → minimax-linux.desktop ✓
x-scheme-handler/minimax-test → minimax-linux.desktop ✓
x-scheme-handler/minimax-cn-test → minimax-linux.desktop ✓
x-scheme-handler/minimax-staging → minimax-linux.desktop ✓
x-scheme-handler/minimax-cn-staging → minimax-linux.desktop ✓
```

### 🟡 P1: asar 4.3.0 extract 工具 bug

`@electron/asar@4.3.0` 的 `extract-file` 命令在含 SHA256 block 的 asar 上报
"was not found in this archive"，但 list 命令工作。**用 asar 3.2.10** 替代或写 Python 解析器
(参考未来要写的 `tools/extract_asar.py`)。

### 🟢 P2: build-deb.sh 性能

`find ... | xargs touch -d` 在 1.3GB PKG_ROOT 上慢（5+ 分钟）。
可改成：cp 完后只 touch 顶层 dir + DEBIAN 几个文件。

### 🟢 P2: headless 测不到 LocalRuntime

`tools/test-ubuntu.sh` 在 docker + Xvfb 里只能验"装包 + 启动到 login 窗口"。
`v2/sqlite/runtime-state.sqlite` 要等 OAuth 登录后才创建 — 这是 **design limitation**，
不是 bug。完整 runtime 验证在 `tools/test-real-machine.sh`。

---

## 7. Bug 修复日志 (按时间倒序)

### 2026-08-28 — 修 Bug 1 (OAuth scheme, 6 种)

**问题**: 外部用户报 web 用 `minimax-code://` 唤不回. 实查 asar `getProtocolNameByEnv()` 动态返回 6 种 scheme (en/zh × prod/test/staging), 但 `.desktop` MimeType 只写 `minimax-cn` → en/test/staging 用户全 100% 唤不回.

**根因**: asar 跟 web 后端都是对的, 6 种都是合法 scheme. 问题在 Linux desktop 端没注册全. 报告人说的 `minimax-code://` 实际不存在 (他大概把 `minimax-code.desktop` 文件名跟 scheme 前缀混了).

**修法** (commit `35cc206`):
- `build-deb.sh` `.desktop` MimeType → 全 6 种
- `build-deb.sh` postinst `xdg-mime default` 循环 6 个 scheme
- `install-protocol-handler.sh` MimeType → 全 6 种

**验证**: 用户机器 6/6 scheme 全部 default 到 `minimax-linux.desktop` ✓

### 2026-08-28 — 修 Bug 3 (StartupWMClass)

**问题**：`.desktop` 写 `StartupWMClass=MiniMax Code`，但 electron 实际窗口 WMClass 是 `mmx-agent-electron`（来自 asar `package.json` `name="@mmx-agent/electron"`, `productName=undefined`）。dock 永远显示齿轮。

**修法**：改 `.desktop` (1 行 diff)。
- `scripts/build-deb.sh:249` `StartupWMClass=MiniMax Code` → `mmx-agent-electron`
- `scripts/install-protocol-handler.sh:94` 同样改

**验证**：`xprop WM_CLASS` 应该返回 `mmx-agent-electron`，GNOME dock 应该显示正确 logo。

### 2026-08-28 — 修 Bug 4 (install-protocol-handler.sh 硬编码路径)

**问题**：`ELEC_BIN="${ELEC43_DIR:-/home/weekbin/Works/repositories/orca/...}"` 写死开发者机器路径，普通用户跑必报 `[ERROR] 找不到 Electron`。

**修法**：用 `BASH_SOURCE` 自定位：
- 先用 `ELEC43_DIR` 环境变量（如有）
- 退到 `<repo>/electron/dist/electron`（如果存在）
- 都没有则给清晰错误（说怎么装 electron）

**附带改动**：
- `PROTOCOL_NAME` 也改成环境变量覆盖（默认 `minimax-cn`）
- 写出的 `.desktop` 名字加 `(dev)` 后缀，避免跟 deb 装的 `minimax-code.desktop` 冲突
- `StartupWMClass` 同步改成 `mmx-agent-electron` (见 Bug 3)

### 2026-08-27 — 修 Bug 2 (Exec 路径空格引号)

**问题**：`Exec=/opt/MiniMax Code/run.sh %u` 含空格，freedesktop spec 要求加引号。

**修法**：`scripts/build-deb.sh:242` 改成 `Exec="/opt/MiniMax Code/run.sh" %u`。

**验证**：`desktop-file-validate` 严格模式不再发 warning；`gio launch` 能正常启动。

### 2026-08-27 — 修 test-ubuntu.sh 假阴性 (state.db 90s timeout)

**问题**：之前 test 用 90s 等 state.db 创建，但 OAuth 登录要人工，headless 跑不到 — 24.04/26.04 一直报 STARTUP_PARTIAL 假阴性。

**修法**：
- 改判定标准: `WindowManager login registered` 即 PASS
- electron timeout 90s → 180s
- 修几轮 `set -u` heredoc 转义 bug
- 加 v2_dir 早期 signal

**验证**：6/6 现有 log 都跟新 matrix 预期一致。

### 2026-08-28 — 抽共享 lib (matrix + parse-log)

**之前**：版本支持矩阵写在 EXPECTED bash 数组里，跟 README/AGENTS 容易漂移。

**修法**：
- `tools/lib/matrix.json` — 单源数据 (glibc/gcc/expected_docker/expected_realmachine/reason)
- `tools/lib/matrix.sh` — bash 接口 (matrix_codename/image/expected/get/versions)
- `tools/lib/parse-log.sh` — `parse_log_status <log> <scope=docker|realmachine>`
- 两个测试脚本都 import 同一个 lib

**附带**：新加 `tools/test-real-machine.sh`（真机/桌面路径，验 OAuth + state.db）。

---

## 8. 常见 troubleshooting

**Symptom**: `dpkg -i` 报缺依赖
→ preinst 没用 sudo 跑。`sudo dpkg -i ...`

**Symptom**: 启动后立刻 `fmod@GLIBC_2.38 not found`
→ shim 没装上或 link patch 没生效
→ 检查 `/opt/mmx-shared/libmmmx.so` 存在
→ `nm -D /opt/.../better_sqlite3.node | grep fmod` 不应再有 `U fmod@GLIBC_2.38`
→ 看 `journalctl -xe | grep minimax-code` 或 `~/.config/MiniMax-Code/logs/main.log`

**Symptom**: 启动后报 `Cannot find package '@earendil-works/pi-tui'`
→ pi-tui 0.84.3 (npm latest) 删了 TUI export。要 0.79.1。
→ 从 `unpacked/app-64/resources/app.asar.orig` 抽 pi-tui 0.79.1 完整 dist/

**Symptom**: LocalRuntime 报 `sqlite: open /lib/.../libm.so.6`
→ shim 的问题，参考 §6 P0

**Symptom**: `dpkg-deb` 卡 1.3GB
→ 正常，zstd 多核压缩需 5-10 分钟。看 `ps aux | grep dpkg-deb` CPU%

---

## 9. 如果你是新 agent 接手

1. **读 `AGENTS.md` (本文件)** — 架构、脚本职责、troubleshooting
2. **读 `README.md`** — 用户视角的快速上手
3. **读 `docs/PIPELINE.md`** — 完整 exe→deb 流程 + Mac/Ubuntu 差异 + input/output 约定 + 已知坑
4. **看 `dist/` 是否存在** — 如果有 .deb，**不要 re-build**，直接拿去装测
5. **如果用户报新 bug** — 优先看 `~/.config/MiniMax-Code/logs/main.log` 和 `journalctl -xe`
6. **如果改 build 脚本** — 改完跑 `build-all.sh` 一次冒烟，再用 noble 容器端到端验
7. **如果升级 electron 版本** — 必须重新跑 `build-linux-gui.sh` + `build-deb.sh`，asar 要重 pack
8. **如果升级 @mmx-agent/electron 版本** — 看 `pi-ai` / `pi-tui` 的 export 变化，可能要重新调整版本对齐

---

## 9. 关键文件位置（不在仓库内，但需要时找得到）

- `/tmp/mmx-app-v3/` — 抽完的 asar 工作目录（44K 文件）
- `/tmp/mmx-linux-install/native-builds/` — native rebuild 临时目录
- `/tmp/minimax-code-deb-build/` — deb 打包 PKG_ROOT（1.3GB）
- `/tmp/asar-tool/` — @electron/asar 4.3.0 (有 bug)
- `/tmp/asar3/` — @electron/asar 3.2.10 (extract 正常，但 list 报假存在)
- `/home/weekbin/Works/repositories/MiniMax-Code-windows/` — 原始 Windows 解包工程
  （**注意** 那个 repo 包含 880MB unpacked 目录，**不要往 linux-mcode-desktop 拷**）

---

## 10. 验证 checklist (新 build 后跑一遍)

- [ ] `dpkg -i` 不用 sudo preinst 也自动装好依赖
- [ ] `minimax-code` 命令启动到 login UI (在 Xvfb 下也 OK)
- [ ] **`tools/test-ubuntu.sh 24.04 26.04`** — 跨版本 docker 冒烟 (2/2 PASS)
- [ ] **`tools/test-real-machine.sh`** — 真机 OAuth + state.db 创建 (release 前)
- [ ] `xdg-mime query default x-scheme-handler/minimax-cn` 返回 `minimax-code.desktop`
- [ ] `xprop WM_CLASS` 返回 `mmx-agent-electron` (跟 `.desktop` StartupWMClass 对齐)
- [ ] better-sqlite3 能 init（`~/.config/MiniMax-Code/v2/sqlite/runtime-state.sqlite` 创建）
- [ ] `nm -D /opt/MiniMax\ Code/app/app-64/resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node`
  显示 `fmod` symbol resolved（不是 `U fmod@GLIBC_2.38`）
- [ ] 在 jammy (GLIBC 2.35) 真机装一遍 + 登录, 看启动有没有 GLIBC 错误
