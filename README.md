# linux-mcode-desktop

把 `MiniMax Code` Windows NSIS 安装包 (`@mmx-agent/electron` v3.0.67-inside.44) 改成可在 Linux 跑的 GUI 客户端，输出 `.deb` + `.tar.gz` + `.tar`。

支持 **Ubuntu 20.04 / 22.04 / 24.04 / 25.04 / 25.10 / 26.04**。

## TL;DR

```bash
# 0) 准备 Windows .exe (gitignored, 留 inputs/ 目录)
cp /path/to/MiniMax-Code-Setup-3.0.67-inside.44.exe inputs/

# 1) 准备 Linux Electron 43.1.0
#    下载 https://github.com/electron/electron/releases/tag/v43.1.0 的
#    `electron-v43.1.0-linux-x64.zip`, 解压到任意路径
export ELEC43_DIR=/path/to/electron-v43.1.0

# 2) 一键打包
npm run build:all

# 3) 装到本机
sudo dpkg -i dist/minimax-code_3.0.67-inside.44_amd64.deb

# 4) 验证
#    A. 跨版本冒烟 (docker headless — CI / 日常)
tools/test-ubuntu.sh 24.04 26.04
#    B. 真机 runtime 验证 (release 前必跑 — 要 GUI + OAuth 账号)
tools/test-real-machine.sh
```

> **双路径验证** (`AGENTS.md §5`):
> - `tools/test-ubuntu.sh` — docker headless，验装包 + 启动到 login 窗口
> - `tools/test-real-machine.sh` — 真机/桌面，验装包 + OAuth + LocalRuntime + state.db
>
> 共用版本支持矩阵 `tools/lib/matrix.json`（单源数据，不会漂移）。
> headless 容器里报 `state_db=missing` = 预期（OAuth 跑不到），**不是 bug**。

---

## 通俗版原理 (4 步)

把 Windows 上的"压缩包版电子应用"拆开 → 换掉 Windows 才有的零件 → 按 Linux 规矩重新装。

```
┌─ 1) 拆箱 (NSIS 解包)
│  NSIS 安装器 = 7z 压缩包 + 引导程序
│  7z x setup.exe → unpacked/app-64/ (跟 Windows 装好后一样的目录)
│
├─ 2) 打开 asar 大 zip (@electron/asar)
│  app.asar 抽出来 4 万多个文件:
│    - dist/main/*.js  (Electron 启动入口)
│    - node_modules/   (3000+ npm 包)
│    - 几个 .node (C++ 编译的 native 模块, Windows 版)
│
│  改三件事:
│    a) Windows .node 重新编译成 Linux .node (4 个: better-sqlite3 / node-pty / libnut / ripgrep)
│    b) JS 里硬编码的 C:\xxx / win32 分支改成 Linux 版本
│    c) pi-tui 0.79.1 从原始 Windows 包抽出 (npm latest 删了 Linux 版)
│
│  asar 重打包
│
├─ 3) 按 Linux 房子 (FHS) 装回去
│  ┌─ Windows 习惯 ──────────┬─ Linux 规矩 ──────────────────┐
│  │ C:\Program Files\App\   │ /opt/MiniMax Code/             │
│  │ 开始菜单快捷方式        │ /usr/share/applications/*.desktop │
│  │ 图标                    │ /usr/share/icons/hicolor/.../*.png │
│  │ PATH 里的 exe           │ /usr/bin/minimax-code          │
│  └─────────────────────────┴────────────────────────────────┘
│  + preinst 脚本: 装 deb 时 apt-get install -f 自动补依赖
│
└─ 4) dpkg-deb 压成 .deb (~227MB)
       → 用户 sudo dpkg -i 装上, 敲 minimax-code 启动
```

**为什么折腾这么久** (3 个大坑):
1. **GLIBC 兼容**: `better_sqlite3` 引用 `fmod@GLIBC_2.38`, 老系统 (jammy 2.35, focal 2.31) `libm.so.6` 没有 → 用 `libfmod_shim.so` 提供 versioned symbol, link 进 .node
2. **pi-tui 没 Linux 版**: npm latest 0.84.3 删了, 从老包抽 0.79.1
3. **asar 抽取 bug**: `@electron/asar@4.3.0` 抽新格式报"was not found" → 降级 3.2.10

详细见 `docs/PIPELINE.md` (800+ 行, 9 个章节)。

---

## 仓库结构 (目录一览)

```
linux-mcode-desktop/
├── inputs/                  用户放 .exe 的目录 (gitignored, README 留路径)
├── scripts/                 7 个 bash 脚本（NSIS → deb 全流程）
├── src/                     关键 patch 源码（libmmmx shim + binding.gyp patch）
├── lib/                     预编译的 native shim (libfmod_shim.so, 14KB)
├── tools/                   验证工具
│   ├── test-ubuntu.sh       路径 B: docker headless 冒烟
│   ├── test-real-machine.sh 路径 A: 真机/桌面 runtime 验证
│   └── lib/                 共享工具 (matrix.json + matrix.sh + parse-log.sh)
├── docs/PIPELINE.md         完整 exe→deb 端到端流程 (Mac/Ubuntu side-by-side)
├── unpacked/                NSIS 解包输出 (gitignored, 由 build-linux-gui.sh 生成)
├── dist/                    deb 产物 (gitignored, 由 build-deb.sh 生成)
├── README.md                你正在读
├── README-LINUX.md          end-user 安装指南 (zh)
├── AGENTS.md                AI agent 看: 架构 / troubleshooting / bug log
└── package.json             npm run build:deb 等脚本
```

### 文件职责速查 (file → purpose)

| 路径 | 作用 |
|---|---|
| `inputs/MiniMax-Code-Setup-3.0.67-inside.44.exe` | Windows NSIS 安装包 (gitignored,目录和 README 保留) |
| `unpacked/app-64/resources/app.asar` | Patch 后的 asar (424 MB) |
| `unpacked/app-64/resources/app.asar.unpacked/` | Linux native binding 注入位置 |
| `scripts/build-linux-gui.sh` | Stage A+B 驱动: NSIS 解包 → asar 抽 → 注入 Linux native → patch JS → repack |
| `scripts/build-in-container.sh` | 在 macOS 上跑全 Linux pipeline (Docker Desktop + qemu amd64) |
| `scripts/build-deb.sh` | Stage C 驱动: 把 unpacked/ + native + shim 打成 .deb |
| `scripts/build-targz.sh` | 打包 .tar.gz (免 root 部署) |
| `scripts/build-all.sh` | 一键跑 build-linux-gui + build-deb + build-targz |
| `scripts/install-protocol-handler.sh` | Dev 模式注册 `minimax[-cn]://` OAuth callback (`BASH_SOURCE` 自定位) |
| `scripts/run-mmx-linux.sh` | 装好后启动客户端 (含 `LD_PRELOAD` shim) |
| `src/libmmmx-shim.c` | fmod@GLIBC_2.38 兼容实现 (jammy/focal 必需) |
| `src/libmmmx-shim.map` | linker version script (限制只能暴露 fmod) |
| `src/build-shim.sh` | 编译 libmmmx.so |
| `src/better-sqlite3-binding.gyp.patch` | 给 better-sqlite3 加 `-lmmmx` 链接选项 |
| `lib/libfmod_shim.so` | 预编译的 fmod shim fallback (committed,14KB) |
| `tools/test-ubuntu.sh` | 路径 B: 跨版本 docker headless 冒烟 (CI / 日常) |
| `tools/test-real-machine.sh` | 路径 A: 真机/桌面 runtime 验证 (OAuth + state.db) |
| `tools/lib/matrix.json` | 版本支持矩阵**单源数据** (glibc / gcc / 预期 / reason) |
| `tools/lib/matrix.sh` | bash 接口: `matrix_codename` / `matrix_image` / `matrix_expected` |
| `tools/lib/parse-log.sh` | log → status token: `parse_log_status <log> <scope>` |
| `docs/PIPELINE.md` | 完整端到端流程 (800+ 行,9 章节,Mac/Ubuntu side-by-side) |
| `AGENTS.md` | AI agent 看: 架构 / 脚本职责 / troubleshooting / bug log (9 章节) |
| `README-LINUX.md` | End-user 安装指南 (zh) |

---

## exe → deb 完整思路 (代码级)

把上节"通俗版原理 4 步"对应到具体脚本和文件:

```
┌─ Stage A: NSIS 解包 + asar 重打包 (scripts/build-linux-gui.sh)
│
│  1. NSIS 自解压 (7z x inputs/*.exe → unpacked/app-64/)
│     ├─ 删 Windows-only 资源: *.dll, *.bin, MiniMax Code.exe
│     └─ 替换为 Linux Electron 43 binary (从 ELEC43_DIR/dist/electron 复制)
│
│  2. @electron/asar 解开 app.asar → /tmp/mmx-app-v3/
│     ├─ 注入 4 个 Linux native binding (替换 Windows .node):
│     │   - better-sqlite3 v12.10.1 (从 source rebuild,GLIBC 匹配目标)
│     │   - node-pty v1.0.0 (同上)
│     │   - @nut-tree/libnut-linux-x64 (N-API,直接用 prebuilt)
│     │   - @vscode/ripgrep-linux-x64 (static-pie,直接用 prebuilt)
│     ├─ Patch JS (GPU disable / open-external / tray / deeplink / mcode-tools)
│     └─ asar 重打包 → unpacked/app-64/resources/app.asar (424MB)
│
│  3. Patch better-sqlite3 链接 (src/better-sqlite3-binding.gyp.patch)
│     └─ ldflags 加 -Wl,-rpath -L /opt/mmx-shared -lmmmx
│        → better_sqlite3.node 链接时把 fmod symbol 绑到 libmmmx
│        → 避开 LD_PRELOAD 被 chromium sandbox 屏蔽的问题
│
├─ Stage B: native binding rebuild (在 Ubuntu 容器内)
│  └─ scripts/build-in-container.sh --tag=24.04 拉 ubuntu:24.04 容器
│     ├─ 装 build 工具链 (g++-13 / clang / node 22)
│     ├─ npm install better-sqlite3@12.10.1 + node-pty (--ignore-scripts)
│     ├─ 隐藏 prebuilds 目录强迫 source build
│     └─ node node-gyp.js rebuild --target=43.1.0 --runtime=electron
│        (命令行参数,不是环境变量 — node-gyp 不读 npm_config_*)
│
├─ Stage C: 打 .deb (scripts/build-deb.sh)
│  ├─ 重组目录结构到 /opt/MiniMax Code/
│  ├─ 注入 4 个 .node 到 app.asar.unpacked/
│  ├─ 注入 libmmmx.so → /opt/mmx-shared/libmmmx.so
│  ├─ 写 /usr/share/applications/minimax-code.desktop
│  │   - Name=MiniMax Code (展示名)
│  │   - StartupWMClass=MiniMax (跟 Electron 实际 WMClass 对齐)
│  │   - MimeType=x-scheme-handler/minimax;minimax-cn;...
│  ├─ 写 DEBIAN/{preinst,postinst,prerm,conffiles}
│  │   - preinst: 只 detect 依赖,提示用户,不抢 apt 锁
│  │   - postinst: 真装依赖 (只缺才 apt-get update + install)
│  └─ dpkg-deb --build → dist/minimax-code_3.0.67-inside.44_amd64.deb (~227MB)
│
├─ Stage D: 双路径验证
│  ├─ 路径 A (CI / 日常): tools/test-ubuntu.sh 24.04 26.04
│  │   └─ 拉 ubuntu:TAG 容器, 装 deb, Xvfb 启动, 验 WindowManager login registered
│  │      判定: scope=docker, 矩阵在 matrix.json:expected_docker
│  └─ 路径 B (release 前): tools/test-real-machine.sh
│      └─ 真机/桌面跑, 验 OAuth + LocalRuntime ready + state.db 创建
│         判定: scope=realmachine, 矩阵在 matrix.json:expected_realmachine
└─ Done
```

**关键设计决策** (这些就是"为什么折腾这么久"的根因):

1. **每个 deb 在对应 Ubuntu 容器内独立 rebuild** — GLIBC 不向上兼容,高 GLIBC 编译的 .node 在低 GLIBC 系统跑不起来
2. **node-gyp 必须 `--target --runtime` 命令行参数** — 环境变量 `npm_config_target=43.1.0` 被 node-gyp 忽略
3. **better-sqlite3 v12.10.1 需要完整 c++20** — g++-10/11 不支持 `<source_location>`,必须 g++-12+ / Clang 15+
4. **fmod shim 链接进 .node 而非 LD_PRELOAD** — chromium sandbox 屏蔽 LD_PRELOAD 传给子进程,链接进 .node 走 rpath 一劳永逸
5. **preinst 只 detect 不 install** — 抢 apt 锁会导致 dpkg 卡 30s+,真装依赖放 postinst
6. **.desktop StartupWMClass 跟 Electron 实际 WMClass 对齐** — 来自 `app.setName(APP_NAME)`,不来自 `package.json.name`

---

## 支持情况总览

**Ubuntu 版本** (单源数据 `tools/lib/matrix.json`):

| 版本 | 代号 | GLIBC | gcc | 装 deb | 真机 runtime | 备注 |
|---|---|---|---|---|---|---|
| **26.04 LTS** | resolute | 2.43+ | 15 | ✅ | ✅ | Resolute Raccoon,最新 LTS,全功能 |
| **24.04 LTS** | noble | 2.39 | 13/14 | ✅ | ✅ | Noble Numbat,**主要验证平台** |
| 25.10 | questing | 2.41 | 14 | ✅ | ✅ | 短支持周期 (9 月 EOL),不推荐生产 |
| 25.04 | plucky | 2.41 | 14 | ✅ | ✅ | 已 EOL,仅供参考 |
| **22.04 LTS** | jammy | 2.35 | 11 | ✅ | ⚠️ | 需 libmmmx.so 真机验证 (见 `AGENTS.md §6` P0) |
| **20.04 LTS** | focal | 2.31 | 9/10 | ✅ | ❌ | GLIBC 太老,better_sqlite3 加载失败 (post-OAuth) |

**Legend**: ✅ 完全支持  ⚠️ 装可,runtime 需额外步骤  ❌ 不支持

> docker 冒烟所有版本都是 PASS (装包+启动到 login),真机测才暴露 GLIBC 问题。

**关键依赖** (按版本差异,完整表见 [docs/PIPELINE.md §4](../docs/PIPELINE.md)):

| 包 | 20.04 | 22.04 | 24.04+ |
|---|---|---|---|
| libdrm2 (>= 2.4.109) | 2.4.107 ❌ | 2.4.114 ✅ | ✅ |
| libnotify4 (>= 0.8.0) | 0.7.9 ❌ | ✅ | ✅ |
| libatk1.0-0 (>= 2.36) | 2.35.1 ❌ | ✅ | ✅ |
| libgtk-3-0 | ✅ | (t64 优先) | (t64 优先) |
| libasound2 / libasound2t64 | `libasound2` | `libasound2t64` | `libasound2t64` |

> preinst 用 `apt-get install -f -y` 解决 version mismatch,包名 alternates 写在 `Depends` 里。

**已知 Bug 状态** (Aug 2026,完整修复日志见 `AGENTS.md §7`):

| Bug | 报告说 | 实际 | 状态 |
|---|---|---|---|
| 1. OAuth scheme 不匹配 | web 用 `minimax-code://` 唤不回 | asar `getProtocolNameByEnv()` 动态 6 种,`.desktop` 只写 `minimax-cn` | ✅ **已修** (`.desktop` MimeType 写全部 6 种) |
| 2. Exec 路径空格未引号 | `Exec=/opt/MiniMax Code/run.sh %u` 启动失败 | 已加引号 | ✅ **已修** |
| 3. StartupWMClass 写错 (`MiniMax Code` vs `mmx-agent-electron`) | dock 显示齿轮 | asar `package.json` 没 productName,实际 WMClass 是 `mmx-agent-electron` | ✅ **已修** (`.desktop` 改 `MiniMax`,匹配 `app.setName()`) |
| 4. `install-protocol-handler.sh` 硬编码 `ELEC_BIN` 路径 | 写死别人跑不了 | `BASH_SOURCE` 自定位 | ✅ **已修** |

**已知未解决问题** (按优先级,详见 `AGENTS.md §6`):

- 🔴 **P0**: jammy/focal 真机 GLIBC 兼容 (libmmmx 已 link 进 .node,未端到端验证)
- 🟡 **P1**: asar 4.3.0 extract 工具 bug (降级 3.2.10 解决)
- 🟢 **P2**: build-deb.sh `find | xargs touch` 性能 (大 PKG_ROOT 慢 5+ 分钟)

---

## 关键 insight (GLIBC 兼容性)

`better-sqlite3 v12` 在 noble (GLIBC 2.39) 上从源码 rebuild 后，会引用
`fmod@GLIBC_2.38`（glibc 2.38 改了 fmod 的 versioned symbol）。jammy (2.35) / focal (2.31) 的
`libm.so.6` 没有这个 symbol。

**修法**: 把 `libmmmx.so`（提供 `fmod@GLIBC_2.38` + `fmod@GLIBC_2.2.5`）**链接进** `better_sqlite3.node`，
让它的 fmod symbol 在 link 阶段就被 shim 提供，避开了 `LD_PRELOAD` 被 chromium sandbox 屏蔽的问题。

详见 [src/libmmmx-shim.c](./src/libmmmx-shim.c) 和 [src/better-sqlite3-binding.gyp.patch](./src/better-sqlite3-binding.gyp.patch)。

---

## 文档

- **[docs/PIPELINE.md](./docs/PIPELINE.md)** — 完整 exe→deb 端到端流程 (800+ 行, 9 章节)
- **[AGENTS.md](./AGENTS.md)** — AI agent 看: 架构 / 脚本职责 / troubleshooting / bug log
- **[README-LINUX.md](./README-LINUX.md)** — end-user 安装指南 (zh)
- **[inputs/README.md](./inputs/README.md)** — .exe 放哪 / 文件命名约定

---

## License

源码（脚本 + shim）：MIT。
**注意**: 编译产物（`app.asar` 内的代码、`unpacked/`、`dist/` 下的 deb/tar）是 **MiniMax / mmx-agent 的版权**，
**不要 commit 到本仓库**。本仓库只放打包逻辑。
