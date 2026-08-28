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

## Ubuntu 版本支持矩阵 (Aug 2026)

| 版本 | 代号 | GLIBC | gcc | libstdc++ | 装 deb | 真机 runtime | 备注 |
|------|------|-------|-----|-----------|--------|--------------|------|
| **26.04 LTS** | resolute | 2.43+ | 15 | recent | ✅ | ✅ | Resolute Raccoon，最新 LTS，全功能 |
| **24.04 LTS** | noble | 2.39 | 13/14 | recent | ✅ | ✅ | Noble Numbat，**主要验证平台** |
| 25.10 | questing | 2.41 | 14 | recent | ✅ | ✅ | 短支持周期 (9 月 EOL)，不推荐生产 |
| 25.04 | plucky | 2.41 | 14 | recent | ✅ | ✅ | 已 EOL, 仅供参考 |
| **22.04 LTS** | jammy | 2.35 | 11 | libstdc++.6.0.30 | ✅ | ⚠️ | 需 libmmmx.so 真机验证 (见 `AGENTS.md §6` P0) |
| **20.04 LTS** | focal | 2.31 | 9/10 | libstdc++.6.0.28 | ✅ | ❌ | GLIBC 太老, better_sqlite3 加载失败 (post-OAuth) |

**Legend**: ✅ 完全支持  ⚠️ 装可，runtime 需额外步骤  ❌ 不支持

> 注: docker 冒烟测试所有版本都是 PASS (装包+启动到 login)，真机测才暴露 GLIBC 问题。
> 矩阵由 `tools/lib/matrix.json` 单源维护。

### 关键依赖 (按版本)

| 包 | 20.04 | 22.04 | 24.04+ |
|----|-------|-------|--------|
| libnss3 / libnspr4 | ✅ | ✅ | ✅ |
| libdrm2 (>= 2.4.109) | 2.4.107 ❌ | 2.4.114 ✅ | ✅ |
| libnotify4 (>= 0.8.0) | 0.7.9 ❌ | ✅ | ✅ |
| libatk1.0-0 (>= 2.36) | 2.35.1 ❌ | ✅ | ✅ |
| libgtk-3-0 | ✅ | (t64 优先) | (t64 优先) |
| libasound2 / libasound2t64 | `libasound2` | `libasound2t64` | `libasound2t64` |

> preinst 用 `apt-get install -f -y` 解决 version mismatch，包名 alternates 写在 `Depends` 里。

---

## 已知 Bug 状态 (从外部 bug 报告排查)

| Bug | 报告说 | 实际 | 状态 |
|-----|--------|------|------|
| 1. OAuth scheme 不匹配 | web 用 `minimax-code://` 唤不回 | asar PROTOCOL_NAME 动态 6 种 (en/zh × prod/test/staging)。原 `.desktop` 只写 `minimax-cn` → en/test/staging 用户唤不回 | ✅ **已修** (`.desktop` MimeType 写全部 6 种) |
| 2. Exec 路径空格未引号 | `Exec=/opt/MiniMax Code/run.sh %u` 启动失败 | `build-deb.sh` 已写 `Exec="/opt/MiniMax Code/run.sh" %u` | ✅ **已修** |
| 3. StartupWMClass 写错 (`MiniMax Code` vs `mmx-agent-electron`) | dock 显示齿轮 | asar `package.json` `name="@mmx-agent/electron"`, `productName=undefined` → 实际 WMClass 是 `mmx-agent-electron` | ✅ **已修** |
| 4. `install-protocol-handler.sh` 硬编码 `ELEC_BIN` 路径 | 写死 `/home/weekbin/...` 别人跑不了 | 用 `BASH_SOURCE` 自定位，找 `<repo>/electron/dist/electron` 或 `ELEC43_DIR` 覆盖 | ✅ **已修** |

详细修复日志见 `AGENTS.md §7`。

---

## 仓库结构

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
