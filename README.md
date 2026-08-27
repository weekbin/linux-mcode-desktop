# linux-mcode-desktop

把 `MiniMax Code` Windows NSIS 安装包 (`@mmx-agent/electron`) 改成可在 Linux 跑的 GUI 客户端，
输出 `.deb` + `.tar.gz` + `.tar`。

## TL;DR

```bash
# 1) 准备 Linux Electron 43.1.0 (任意路径, 改 ELEC43_DIR)
ELEC43_DIR=/path/to/electron-43 npm run build

# 2) 装到本机
sudo dpkg -i dist/minimax-code_3.0.67-inside.44_amd64.deb

# 3) 跨版本冒烟测试 (docker)
tools/test-ubuntu.sh 24.04
```

## Ubuntu 版本支持矩阵 (Aug 2026)

| 版本 | 代号 | GLIBC | gcc | libstdc++ | 装 deb | runtime | 备注 |
|------|------|-------|-----|-----------|--------|---------|------|
| **26.04 LTS** | resolute | 2.43+ | 15 | recent | ✅ | ✅ | Resolute Raccoon, 最新 LTS, 全功能 |
| **24.04 LTS** | noble | 2.39 | 13/14 | recent | ✅ | ✅ | Noble Numbat, 主要验证平台 |
| 25.10 | questing | 2.41 | 14 | recent | ✅ | ✅ | 短支持周期 (9 月 EOL)，不推荐生产 |
| 25.04 | plucky | 2.41 | 14 | recent | ✅ | ✅ | 已 EOL, 仅供参考 |
| **22.04 LTS** | jammy | 2.35 | 11 | libstdc++.6.0.30 | ✅ | ⚠️ | 需 libmmmx.so 链接验证 (见 AGENTS §6 P0) |
| **20.04 LTS** | focal | 2.31 | 9/10 | libstdc++.6.0.28 | ❌ | ❌ | GLIBC 太老, V8 symbols 不全 |

**Legend**: ✅ 完全支持  ⚠️ 装可，runtime 需额外步骤  ❌ 不支持

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

## 文档

- **[AGENTS.md](./AGENTS.md)** — 给 AI agent 看的：架构、脚本职责、troubleshooting、已知问题
- **[tools/test-ubuntu.sh](./tools/test-ubuntu.sh)** — 跨 Ubuntu 版本自动冒烟测试
- **[scripts/](./scripts/)** — 6 个 bash 脚本，从 NSIS 到 .deb 全流程
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
