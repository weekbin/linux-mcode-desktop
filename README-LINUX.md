# MiniMax Code (Linux)

Linux GUI client built from the Windows NSIS installer via
`@mmx-agent/electron v3.0.73`.

**打包逻辑仓库**: https://github.com/weekbin/linux-mcode-desktop
（脚本、patch、shim 源码；deb/tar 产物不 commit）

## Install

```bash
sudo dpkg -i minimax-code_3.0.73_amd64.deb
# 如果装包报缺依赖 (preinst 失败):
sudo apt-get install -f -y
sudo dpkg --configure -a
```

免 root 版本用 tar.gz:

```bash
tar -xzf minimax-code_3.0.73_linux-x64.tar.gz
cd minimax-code-3.0.73-linux-x64
./install.sh                 # 装到 ~/.local (用户级)
# 或 ./bin/minimax-code      # 不解压安装直接跑
```

## Launch

```bash
minimax-code
# 或
/opt/MiniMax\ Code/run.sh
```

`run.sh` / tar.gz 的 wrapper 启动时自动 `LD_PRELOAD` `libfmod_shim.so`
（提供 `fmod@GLIBC_2.38`，兼容老 GLIBC 系统），无需手动设。

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
sudo dpkg --purge minimax-code        # deb 版
./uninstall.sh                         # tar.gz 版 (PREFIX 一致)
```

## Notes

- On headless servers: `xvfb-run -a minimax-code` or set `DISPLAY=:99`
  with a running `Xvfb`。
- OAuth callback scheme: `.desktop` / postinst / install.sh 注册了全部 6 种
  (`minimax` / `minimax-cn` / `*-test` / `*-staging`, en/zh × prod/test/staging)，
  跟 asar 内 `getProtocolNameByEnv()` 一致。
- GNOME dock 图标需 electron 实际 WMClass `mmx-agent-electron`
  (`.desktop` `StartupWMClass` 已对齐)。

## Where things live (after install)

deb 版:
```
/opt/MiniMax Code/
├── app/app-64/resources/app.asar          # JS + native
├── libfmod_shim.so                        # fmod@GLIBC_2.38 shim
├── run.sh                                  # LD_PRELOAD wrapper
└── electron/dist/electron                  # electron 43

/usr/share/applications/minimax-code.desktop  # MIME + StartupWMClass
/usr/bin/minimax-code                         # /usr/bin wrapper
```

tar.gz 版 (PREFIX 默认 ~/.local):
```
$PREFIX/share/minimax-code/
├── app/app-64/resources/app.asar
├── libfmod_shim.so
└── electron/dist/electron
$PREFIX/bin/minimax-code                      # LD_PRELOAD wrapper
$PREFIX/share/applications/minimax-code.desktop
```

用户数据 (登录后创建):
```
~/.config/MiniMax-Code/
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
