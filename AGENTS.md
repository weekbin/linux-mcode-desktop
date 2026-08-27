# AGENTS.md — 给 AI Agent 看的操作指南

> 接手这个 repo 的 agent，请从头读这份文档。**目标**：把 `MiniMax Code`
> Windows NSIS 安装包 (`@mmx-agent/electron v3.0.67-inside.44`) 转成可在
> Ubuntu 24.04+ 上运行的 Linux GUI 客户端。

---

## 1. 仓库结构

```
linux-mcode-desktop/
├── scripts/
│   ├── build-linux-gui.sh   # 核心: NSIS 解包 → asar 抽 → 注入 Linux native → patch JS → repack
│   ├── build-deb.sh         # 把 unpacked/ 打成 .deb
│   ├── build-targz.sh       # 打包 .tar.gz (可移植版本)
│   ├── build-all.sh         # 编排: build-linux-gui + build-deb + build-targz
│   ├── install-protocol-handler.sh  # 注册 minimax-cn:// OAuth callback
│   └── run-mmx-linux.sh     # 装好后启动客户端
├── src/
│   ├── libmmmx-shim.c       # 提供 fmod@GLIBC_2.38 的 shim
│   ├── libmmmx-shim.map     # linker version script
│   ├── build-shim.sh        # 编译 shim
│   └── better-sqlite3-binding.gyp.patch  # 给 better-sqlite3 加 -lmmmx 的 patch
├── README.md
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

## 5. 端到端验证

### 5.1 单版本快速测 (noble)

```bash
# 在 Ubuntu 24.04 noble 容器:
docker run -it --rm -v /tmp/.X11-unix:/tmp/.X11-unix -e DISPLAY ubuntu:24.04 bash
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libnss3 libdrm2 libnotify4 libgbm1 libxkbcommon0 xdg-utils xvfb

# 装 deb
dpkg -i /path/to/minimax-code_3.0.67-inside.44_amd64.deb

# 启动 (X server 必需, 用 Xvfb)
Xvfb :99 -screen 0 1280x800x24 &
export DISPLAY=:99
/opt/MiniMax\ Code/run.sh

# 看 log 看 LocalRuntimeUtility ready
```

成功 log 关键 marker：
```
[info]  [LocalRuntime] Launch plan: buildEnv=prod
[info]  [LocalRuntimeUtility] runtime started
[info]  [WindowManager] Registered window: type=login, id=1
```

### 5.2 跨版本自动测试 (`tools/test-ubuntu.sh`)

**支持版本** (Aug 2026):
| 版本 | 代号 | GLIBC | 预期 | 测过 |
|------|------|-------|------|------|
| 20.04 | focal | 2.31 | FAIL | ❌ GLIBC 太老, V8 symbols 不全 |
| 22.04 | jammy | 2.35 | PARTIAL | ⚠️ 装可, runtime 需 shim 链接 |
| 24.04 | noble | 2.39 | PASS | ✅ |
| 25.04 | plucky | 2.41 | PASS | ✅ (EOL) |
| 25.10 | questing | 2.41+ | PASS | ✅ (短期) |
| 26.04 | resolute | 2.43+ | PASS | ✅ |

**用法**:
```bash
# 测所有支持版本 (推荐, 跑一次冒烟)
tools/test-ubuntu.sh

# 只测某个版本
tools/test-ubuntu.sh 24.04
tools/test-ubuntu.sh 26.04

# 测完保留容器 (debug)
tools/test-ubuntu.sh --no-cleanup 24.04

# 自定义 deb 路径
DEB_PATH=/path/to/deb tools/test-ubuntu.sh 24.04
```

**前置**:
- docker (镜像会自动 pull)
- 已 build 的 `dist/minimax-code_3.0.67-inside.44_amd64.deb`
- 充足磁盘 (每个容器临时 ~2GB)

**log 位置**: `.test-logs/<codename>.log` (在仓库内, .gitignore 排除)

**exit code**:
- 0 = 所有版本都符合预期
- 1 = 有版本跟预期不符 (通常是新发现的 bug)

### 5.3 手动 debug 单个版本

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

---

## 6. 已知未解决问题（按优先级）

### 🔴 P0: GLIBC 兼容性（多个 OS 不支持）

**问题**：
- electron 43 chromium 内部用 GLIBC 2.38 symbols（`__libc_single_threaded`, `fmod` 等）
- noble: GLIBC 2.39 ✅
- jammy: GLIBC 2.35 ❌
- focal: GLIBC 2.31 ❌

**当前状态**：
- shim 已写好（`src/libmmmx-shim.c`），link patch 准备好（`src/better-sqlite3-binding.gyp.patch`）
- **未在 jammy/focal 容器端到端验证过 shim 链接后的 better_sqlite3.node 能否真的加载**
- shim 通过 `LD_PRELOAD` 在 main process 工作，**但被 chromium sandbox 屏蔽**（child process 不继承）
- patchelf 给 `better_sqlite3.node` 加 NEEDED 失败，因为 electron 把 `.node` 复制到
  `/tmp/.org.chromium.Chromium.<random>` 加载，patchelf 不影响副本

**下一步方案**（任选一）：
1. **A. objcopy hack** — `objcopy --redefine-syms` 改 fmod 的 versioned symbol 表
2. **B. LD_AUDIT** — 用 audit interface 强制注入到所有 child process
3. **C. 换 electron 30** — electron 30 还没用 GLIBC 2.38 的 symbols，工作量很大
4. **D. 换 WASM sqlite** — 用 `node-sqlite3-wasm`，零 native GLIBC，**唯一干净路线**，
   但要改 `@mavis/local-runtime` 代码
5. **E. 只支持 noble** — 文档化限制

### 🟡 P1: asar 4.3.0 extract 工具 bug

`@electron/asar@4.3.0` 的 `extract-file` 命令在含 SHA256 block 的 asar 上报
"was not found in this archive"，但 list 命令工作。**用 asar 3.2.10** 替代或写 Python 解析器
(参考未来要写的 `tools/extract_asar.py`)。

### 🟢 P2: build-deb.sh 性能

`find ... | xargs touch -d` 在 1.3GB PKG_ROOT 上慢（5+ 分钟）。
可改成：cp 完后只 touch 顶层 dir + DEBIAN 几个文件。

---

## 7. 常见 troubleshooting

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

## 8. 如果你是新 agent 接手

1. **读 `AGENTS.md` (本文件)** — 架构、脚本职责、troubleshooting
2. **读 `README.md`** — 用户视角的快速上手
3. **看 `dist/` 是否存在** — 如果有 .deb，**不要 re-build**，直接拿去装测
4. **如果用户报新 bug** — 优先看 `~/.config/MiniMax-Code/logs/main.log` 和 `journalctl -xe`
5. **如果改 build 脚本** — 改完跑 `build-all.sh` 一次冒烟，再用 noble 容器端到端验
6. **如果升级 electron 版本** — 必须重新跑 `build-linux-gui.sh` + `build-deb.sh`，asar 要重 pack
7. **如果升级 @mmx-agent/electron 版本** — 看 `pi-ai` / `pi-tui` 的 export 变化，可能要重新调整版本对齐

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
- [ ] `LocalRuntimeUtility` log 显示 "runtime started"
- [ ] OAuth callback (用 `xdg-mime` 测: `xdg-mime query default x-scheme-handler/minimax-cn`)
- [ ] better-sqlite3 能 init（`~/.config/MiniMax-Code/state.db` 出现）
- [ ] `nm -D /opt/MiniMax\ Code/app/app-64/resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node`
  显示 `fmod` symbol resolved（不是 `U fmod@GLIBC_2.38`）
- [ ] 在 jammy (GLIBC 2.35) 容器装一遍，看启动有没有 GLIBC 错误
