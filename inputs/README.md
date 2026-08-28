# inputs/ — Windows NSIS 安装包存放目录

> ⚠️ **不要 commit 这个目录里的内容**（已被 `.gitignore` 排除）

把 Windows NSIS 安装包放到这里，名字固定为:

```
inputs/MiniMax-Code-Setup-3.0.67-inside.44.exe
```

**版本** `3.0.67-inside.44` 必须跟 `scripts/build-deb.sh` / `tools/lib/matrix.json` 里
记录的版本一致。装新版本时同步改:
- `scripts/build-deb.sh` 里 `PACKAGE_NAME` 的版本号
- `tools/lib/matrix.json` 没有硬编码版本号，但 deb 路径 `${VERSION}` 会改
- README 里的 TL;DR 命令路径

**获取来源**: MiniMax / mmx-agent 官方下载页面（见公司 wiki / 飞书）。

## 验证文件放对了

```bash
ls -lh inputs/
# 应该看到:
# MiniMax-Code-Setup-3.0.67-inside.44.exe
# 大约 370 MB, 文件类型: PE32+ executable (GUI) x86-64, for MS Windows
```

## 文件不在这的话

```bash
# 1) 下载 (e.g. 从公司内网 mirror)
cp /path/to/MiniMax-Code-Setup-3.0.67-inside.44.exe inputs/

# 2) 跑 build-linux-gui.sh 自动解包
npm run build:linux-gui
# 或
bash scripts/build-linux-gui.sh

# 3) 跑 build-deb.sh 打 deb
bash scripts/build-deb.sh
```

## 为什么不直接 commit

- `.exe` 是 MiniMax / mmx-agent 的版权内容，**不应该**进这个仓库
- `.gitignore` 里同时有 `*.exe` + `inputs/` 双重排除（双重保险）
- 但 `inputs/` 目录本身 + `inputs/README.md`（本文件）会保留在 repo 里，让别人
  一看就知道 exe 该往哪放
