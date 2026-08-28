# linux-mcode-desktop

把 `MiniMax Code` Windows NSIS 安装包 (`@mmx-agent/electron`) 改成可在 Linux 跑的 GUI 客户端，
输出 `.deb` + `.tar.gz` + `.tar`。

## TL;DR

```bash
# 1) 准备 Linux Electron 43.1.0 (任意路径, 改 ELEC43_DIR)
ELEC43_DIR=/path/to/electron-43 npm run build

# 2) 装到本机
sudo dpkg -i dist/minimax-code_3.0.67-inside.44_amd64.deb

# 3) 跨版本冒烟测试 (docker headless — CI / 日常)
tools/test-ubuntu.sh 24.04 26.04

# 4) 真机/桌面 runtime 验证 (release 前必跑 — 要 GUI + OAuth 账号)
tools/test-real-machine.sh
```

> **双路径验证** (`AGENTS.md §5`):
> - `tools/test-ubuntu.sh` — docker headless, 验装包+启动到 login 窗口
> - `tools/test-real-machine.sh` — 真机/桌面, 验装包+OAuth+LocalRuntime+state.db
>
> 共用版本支持矩阵 `tools/lib/matrix.json`（单源数据，不会漂移）。
> headless 容器里报 `state_db=missing` = 预期（OAuth 跑不到），**不是 bug**。

## Ubuntu 版本支持矩阵 (Aug 2026)

| 版本 | 代号 | GLIBC | gcc | libstdc++ | 装 deb | 真机 runtime | 备注 |
|------|------|-------|-----|-----------|--------|--------------|------|
| **26.04 LTS** | resolute | 2.43+ | 15 | recent | ✅ | ✅ | Resolute Raccoon, 最新 LTS, 全功能 |
| **24.04 LTS** | noble | 2.39 | 13/14 | recent | ✅ | ✅ | Noble Numbat, 主要验证平台 |
| 25.10 | questing | 2.41 | 14 | recent | ✅ | ✅ | 短支持周期 (9 月 EOL)，不推荐生产 |
| 25.04 | plucky | 2.41 | 14 | recent | ✅ | ✅ | 已 EOL, 仅供参考 |
| **22.04 LTS** | jammy | 2.35 | 11 | libstdc++.6.0.30 | ✅ | ⚠️ | 需 libmmmx.so 真机验证 (见 `AGENTS.md §6` P0) |
| **20.04 LTS** | focal | 2.31 | 9/10 | libstdc++.6.0.28 | ✅ | ❌ | GLIBC 太老, better_sqlite3 加载失败 (post-OAuth) |

**Legend**: ✅ 完全支持  ⚠️ 装可，runtime 需额外步骤  ❌ 不支持

> 注: docker 冒烟测试所有版本都是 PASS (装包+启动到 login), 真机测才暴露 GLIBC 问题。
> 矩阵由 `tools/lib/matrix.json` 单源维护。

## 关键依赖 (按版本)

| 包 | 20.04 | 22.04 | 24.04 | 25.04 | 25.10 | 26.04 |
|----|-------|-------|-------|-------|-------|-------|
| libnss3 / libnspr4 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| libdrm2 (>= 2.4.109) | 2.4.107 ❌ | 2.4.114 ✅ | ✅ | ✅ | ✅ | ✅ |
| libnotify4 (>= 0.8.0) | 0.7.9 ❌ | ✅ | ✅ | ✅ | ✅ | ✅ |
| libatk1.0-0 (>= 2.36) | 2.35.1 ❌ | ✅ | ✅ | ✅ | ✅ | ✅ |
| libgtk-3-0 | ✅ | (t64 优先) | (t64 优先) | (t64 优先) | (t64 优先) | (t64 优先) |
| libasound2 / libasound2t64 | `libasound2` | `libasound2t64` | `libasound2t64` | `libasound2t64` | `libasound2t64` | `libasound2t64` |

> preinst 会用 `apt-get install -f -y` 解决 version mismatch，包名 alternates 写在 `Depends` 里。

## 已知 Bug 状态 (从外部 bug 报告排查)

| Bug | 报告说 | 实际 | 状态 |
|-----|--------|------|------|
| 1. OAuth scheme 不匹配 | web 用 `minimax-code://` 唤不回 | asar PROTOCOL_NAME 动态 6 种 (en/zh × prod/test/staging)。原 `.desktop` 只写 `minimax-cn` → en/test/staging 用户唤不回 | ✅ **已修** (`.desktop` MimeType 写全部 6 种, `xdg-mime default` 全部 6 个) |
| 2. Exec 路径空格未引号 | `Exec=/opt/MiniMax Code/run.sh %u` 启动失败 | `build-deb.sh` 已写 `Exec="/opt/MiniMax Code/run.sh" %u` | ✅ **已修** |
| 3. StartupWMClass 写错 (`MiniMax Code` vs `mmx-agent-electron`) | dock 显示齿轮 | asar `package.json` `name="@mmx-agent/electron"`, `productName=undefined` → 实际 WMClass 是 `mmx-agent-electron` | ✅ **已修** |
| 4. `install-protocol-handler.sh` 硬编码 `ELEC_BIN` 路径 | 写死 `/home/weekbin/...` 别人跑不了 | 用 `BASH_SOURCE` 自定位，找 `<repo>/electron/dist/electron` 或 `ELEC43_DIR` 覆盖 | ✅ **已修** |

## 文档

- **[docs/PIPELINE.md](./docs/PIPELINE.md)** — 完整 exe→deb 端到端流程（Mac/Ubuntu side-by-side, input/output 约定, 已知坑）
- **[AGENTS.md](./AGENTS.md)** — 给 AI agent 看的：架构、脚本职责、troubleshooting、已知问题、bug 修复日志
- **[tools/test-ubuntu.sh](./tools/test-ubuntu.sh)** — docker headless 冒烟测试
- **[tools/test-real-machine.sh](./tools/test-real-machine.sh)** — 真机/桌面 runtime 验证
- **[tools/lib/](./tools/lib/)** — 共享工具 (matrix.json + matrix.sh + parse-log.sh)
- **[scripts/](./scripts/)** — 7 个 bash 脚本，从 NSIS 到 .deb 全流程 + protocol handler
- **[src/](./src/)** — 关键 patch 源码（libmmmx shim + binding.gyp patch）

## 架构（30 秒版）

```
Windows NSIS .exe (用户提供)
  ↓ scripts/build-linux-gui.sh
  ├── 7z/nsis 解包
  ├── @electron/asar 抽 app.asar (44K 文件)
  ├── 注入 Linux native bindings 替代 Windows DLL
  ├── patch JS (GPU disable / openExternal / tray / deeplink / mcode-tools)
  └── repack app.asar
  ↓ scripts/build-deb.sh
  ├── 把 unpacked/app-64 + electron 43 复制到 PKG_ROOT
  ├── 把 libmmmx shim 放到 /opt/mmx-shared/
  ├── 注入 asar.unpacked/ Linux natives
  ├── 生成 /usr/share/applications/minimax-code.desktop
  │   (StartupWMClass=mmx-agent-electron, Exec 引号处理空格, MimeType=minimax-cn)
  ├── 生成 DEBIAN/{preinst,postinst,prerm,conffiles,control}
  └── dpkg-deb --build
  ↓ dist/minimax-code_3.0.67-inside.44_amd64.deb (~227MB)
```

## 关键 insight（GLIBC 兼容性）

`better-sqlite3 v12` 在 noble (GLIBC 2.39) 上从源码 rebuild 后，会引用
`fmod@GLIBC_2.38`（glibc 2.38 改了 fmod 的 versioned symbol）。jammy (2.35) / focal (2.31) 的
`libm.so.6` 没有这个 symbol。

当前策略：把 `libmmmx.so`（提供 `fmod@GLIBC_2.38` + `fmod@GLIBC_2.2.5`）链接进
`better_sqlite3.node`，让它的 fmod symbol 在 link 阶段就被 shim 提供。
详见 [src/libmmmx-shim.c](./src/libmmmx-shim.c) 和 [src/better-sqlite3-binding.gyp.patch](./src/better-sqlite3-binding.gyp.patch)。

## License

源码（脚本 + shim）：MIT。
注意：编译产物（`app.asar` 内的代码、`unpacked/`、`dist/` 下的 deb/tar）是
**MiniMax / mmx-agent 的版权**，**不要 commit 到本仓库**。本仓库只放打包逻辑。
