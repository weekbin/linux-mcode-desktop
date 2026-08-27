# linux-mcode-desktop

把 `MiniMax Code` Windows NSIS 安装包 (`@mmx-agent/electron`) 改成可在 Linux 跑的 GUI 客户端，
输出 `.deb` + `.tar.gz` + `.tar`，在 Ubuntu 24.04 (Noble) 上完整可用。

## TL;DR

```bash
# 1) 准备 Linux Electron 43.1.0 (任意路径, 改 ELEC43_DIR)
ELEC43_DIR=/path/to/electron-43 npm run build

# 2) 装到本机
sudo dpkg -i dist/minimax-code_3.0.67-inside.44_amd64.deb
# 或者直接跑: ./scripts/run-mmx-linux.sh
```

## 当前状态 (Aug 2026)

| 组件 | 状态 | 备注 |
|------|------|------|
| 自动依赖装 (preinst `apt-get install -f -y`) | ✅ | 处理 version mismatch |
| `app.asar.unpacked` 注入 Linux natives | ✅ | better-sqlite3 / node-pty / libnut / ripgrep |
| `@earendil-works/pi-tui` 0.79.1 (含 TUI export) | ✅ | 从 asar.orig 抽出，不能用 npm latest (0.84.3 已删 TUI) |
| `libfmod_shim.so` 提供 `fmod@GLIBC_2.38` | ⚠️ | shim 已打，但 shim 链接 better_sqlite3.node 在新环境**未端到端验证** |
| Linux native runtime 启动 login UI | ✅ | noble 容器验证通过 |
| LocalRuntimeUtility + OAuth callback | ✅ | noble 容器验证通过 |
| Ubuntu 24.04 (Noble, GLIBC 2.39) | ✅ | **唯一完整支持** |
| Ubuntu 22.04 (Jammy, GLIBC 2.35) | ⚠️ | 安装可，但 runtime 需 libmmmx.so 链接验证 |
| Ubuntu 20.04 (Focal, GLIBC 2.31) | ❌ | GLIBC 太老，连 electron 43 的 V8 symbols 都跑不动 |

## 文档

- **[AGENTS.md](./AGENTS.md)** — 给 AI agent 看的：架构、脚本职责、troubleshooting、当前已知未解决问题
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
`libm.so.6` 没有这个 symbol，导致：

```
/lib/x86_64-linux-gnu/libm.so.6: version `GLIBC_2.38' not found
  (required by /tmp/.org.chromium.Chromium.<random>)
```

当前策略：把 `libmmmx.so`（提供 `fmod@GLIBC_2.38` + `fmod@GLIBC_2.2.5`）链接进
`better_sqlite3.node`，让它的 fmod symbol 在 link 阶段就被 shim 提供，运行时不需要从 system libm 找。
详见 [src/libmmmx-shim.c](./src/libmmmx-shim.c) 和 [src/better-sqlite3-binding.gyp.patch](./src/better-sqlite3-binding.gyp.patch)。

## License

源代码（脚本 + shim）：MIT。
注意：编译产物（`app.asar` 内的代码、`unpacked/`、`dist/` 下的 deb/tar）是
**MiniMax / mmx-agent 的版权**，**不要 commit 到本仓库**。本仓库只放打包逻辑。
