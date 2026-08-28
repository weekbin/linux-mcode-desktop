# MiniMax Code (Linux)

Linux GUI client built from the Windows NSIS installer via
`@mmx-agent/electron v3.0.67-inside.44`.

**打包逻辑仓库**: https://github.com/weekbin/linux-mcode-desktop
（脚本、patch、shim 源码；deb/tar 产物不 commit）

## Install

```bash
sudo dpkg -i minimax-code_3.0.67-inside.44_amd64.deb
# 如果装包报缺依赖 (preinst 失败):
sudo apt-get install -f -y
sudo dpkg --configure -a
```

## Launch

```bash
minimax-code
# 或
/opt/MiniMax\ Code/run.sh
```

`run.sh` 自动 `LD_PRELOAD` 加载 `/opt/mmx-shared/libmmmx.so`（提供 `fmod@GLIBC_2.38`
兼容老 GLIBC 系统），无需手动设。

## Supported Ubuntu versions

| 版本 | 代号 | 装 deb | 真机 runtime | 备注 |
|------|------|--------|--------------|------|
| **24.04 LTS** | noble | ✅ | ✅ | 主验证平台 |
| **26.04 LTS** | resolute | ✅ | ✅ | 最新 LTS |
| 25.10 | questing | ✅ | ✅ | 短支持周期 |
| 25.04 | plucky | ✅ | ✅ | 已 EOL |
| **22.04 LTS** | jammy | ✅ | ⚠️ | 需 libmmmx 链接验证 |
| **20.04 LTS** | focal | ✅ | ❌ | GLIBC 2.31 太老 |

矩阵由 `tools/lib/matrix.json` 单源维护。

## Uninstall

```bash
sudo dpkg --purge minimax-code
```

## Notes

- On headless servers: `xvfb-run -a minimax-code` or set `DISPLAY=:99`
  with a running `Xvfb`。
- OAuth callback scheme 当前固定 zh 版 `x-scheme-handler/minimax-cn`。
  en / test / staging 用户的实际 scheme 见 `AGENTS.md §6 P1`。
- GNOME dock 图标在 24.04/26.04 上需 electron 实际 WMClass `mmx-agent-electron`
  (已修，commit 见 `AGENTS.md §7`)。

## Where things live (after install)

```
/opt/MiniMax Code/
├── app/app-64/resources/app.asar          # JS + native (44K 文件)
├── run.sh                                  # LD_PRELOAD wrapper
└── electron/dist/electron                  # electron 43.1.0

/opt/mmx-shared/libmmmx.so                  # fmod@GLIBC_2.38 shim

/usr/share/applications/minimax-code.desktop  # MIME + StartupWMClass
/usr/bin/minimax-code                         # /usr/bin wrapper

~/.config/MiniMax-Code/                      # 用户数据 (登录后创建)
├── v2/sqlite/runtime-state.sqlite           # LocalRuntime state
├── logs/main.log                            # 调试 log
└── Local Storage/                           # electron level
```

## 调试

```bash
# 实时看 log
tail -f ~/.config/MiniMax-Code/logs/main.log

# OAuth scheme 验
xdg-mime query default x-scheme-handler/minimax-cn

# 窗口 WMClass
xprop WM_CLASS

# 测协议唤回
xdg-open 'minimax-cn://test'
```
