#!/usr/bin/env bash
# build-deb.sh — 把 MiniMax Code Linux GUI 客户端打成 .deb 包
#
# 输出:
#   dist/minimax-code_<version>_amd64.deb
#
# 包结构:
#   /opt/MiniMax Code/         — Electron 43 + app.asar
#   /usr/bin/minimax-code      — 启动 wrapper
#   /usr/share/applications/   — .desktop
#   /usr/share/icons/hicolor/  — 多尺寸 PNG 图标
#
# 依赖声明: 跟 Electron 43 通用 Linux 需求一致
# 体积: ~500MB (xz 压缩) — 包含 312MB Electron + 451MB app.asar

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
WORK_DIR="/tmp/minimax-code-deb-build"
PACKAGE_NAME="minimax-code"
APP_DISPLAY_NAME="MiniMax Code"
VERSION="3.0.67-inside.44"
ARCH="amd64"
MAINTAINER="MiniMax Linux Packager <[email protected]>"
DESCRIPTION="MiniMax Code Linux GUI client (built from Windows NSIS via @mmx-agent/electron v${VERSION})"

# 源文件
ELEC43_SRC="${ELEC43_DIR:-/home/weekbin/Works/repositories/orca/node_modules/.pnpm/electron@43.1.0/node_modules/electron}"
APP_ASAR_SRC="$PROJECT_ROOT/unpacked/app-64"
ICON_PNG_SRC="$PROJECT_ROOT/unpacked/app-64/resources/resources/icon.png"

# 检查依赖
if [ ! -x "$ELEC43_SRC/dist/electron" ]; then
  echo "[ERROR] 找不到 Linux Electron 43: $ELEC43_SRC" >&2
  exit 1
fi
if [ ! -d "$APP_ASAR_SRC" ]; then
  echo "[ERROR] 找不到 app.asar 目录: $APP_ASAR_SRC" >&2
  echo "  请先跑 scripts/build-linux-gui.sh" >&2
  exit 1
fi
if [ ! -f "$ICON_PNG_SRC" ]; then
  echo "[ERROR] 找不到 icon.png: $ICON_PNG_SRC" >&2
  exit 1
fi

# 准备 clean work dir
echo "[deb] 准备 build dir: $WORK_DIR"
mavis-trash "$WORK_DIR" 2>/dev/null || rm -rf "$WORK_DIR" 2>/dev/null || true
mkdir -p "$WORK_DIR"
PKG_ROOT="$WORK_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}"
mkdir -p "$PKG_ROOT/DEBIAN"
mkdir -p "$PKG_ROOT/opt/MiniMax Code"
mkdir -p "$PKG_ROOT/usr/bin"
mkdir -p "$PKG_ROOT/usr/share/applications"
mkdir -p "$PKG_ROOT/usr/share/icons/hicolor"
mkdir -p "$PKG_ROOT/usr/share/doc/${PACKAGE_NAME}"

# ===== 1) /opt/MiniMax Code/electron/ — Electron 43 =====
echo "[deb] 复制 Electron 43 -> /opt/MiniMax Code/electron/"
cp -r "$ELEC43_SRC" "$PKG_ROOT/opt/MiniMax Code/electron-tmp"
mv "$PKG_ROOT/opt/MiniMax Code/electron-tmp" "$PKG_ROOT/opt/MiniMax Code/electron"
chmod -R go+rX "$PKG_ROOT/opt/MiniMax Code/electron"

# ===== 2) /opt/MiniMax Code/app/ — 只复制 resources/ (asar + icons) =====
# unpacked/app-64/ 包含 Windows electron client (232MB exe + DLLs) — 不需要
# 我们只要 resources/app.asar (改好的 Linux 版) + resources/ (图标等)
echo "[deb] 复制 app.asar + resources -> /opt/MiniMax Code/app/"
mkdir -p "$PKG_ROOT/opt/MiniMax Code/app"
mkdir -p "$PKG_ROOT/opt/MiniMax Code/app/app-64"
# 只复制 resources/ 子目录（asar + 图标 + unpacked native bindings）
cp -r "$APP_ASAR_SRC/resources" "$PKG_ROOT/opt/MiniMax Code/app/app-64/resources"
# 删 Windows backup 减小体积
rm -f "$PKG_ROOT/opt/MiniMax Code/app/app-64/resources/app.asar.orig"
rm -f "$PKG_ROOT/opt/MiniMax Code/app/app-64/resources/elevate.exe"

# === mmx-patch: 用 Linux native binding 替换 Windows .node DLL ===
# 这是 Electron 43 真正跑起来的关键: .node 文件必须放在 asar.unpacked/ 下 (native dlopen 不能从 asar 内)
LINUX_NATIVE_DIR="${LINUX_NATIVE_DIR:-/tmp/mmx-app-v3/node_modules}"
UNPACKED_DST="$PKG_ROOT/opt/MiniMax Code/app/app-64/resources/app.asar.unpacked"
if [ -f "$LINUX_NATIVE_DIR/better-sqlite3/build/Release/better_sqlite3.node" ]; then
    echo "[deb] 注入 Linux native bindings 到 asar.unpacked/ ..."
    # better-sqlite3
    mkdir -p "$UNPACKED_DST/node_modules/better-sqlite3/build/Release"
    cp -f "$LINUX_NATIVE_DIR/better-sqlite3/build/Release/better_sqlite3.node" \
          "$UNPACKED_DST/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
    # node-pty
    mkdir -p "$UNPACKED_DST/node_modules/node-pty/build/Release"
    cp -f "$LINUX_NATIVE_DIR/node-pty/build/Release/pty.node" \
          "$UNPACKED_DST/node_modules/node-pty/build/Release/pty.node"
    # @nut-tree/libnut-linux
    mkdir -p "$UNPACKED_DST/node_modules/@nut-tree/libnut-linux/build/Release"
    cp -f "$LINUX_NATIVE_DIR/@nut-tree/libnut-linux/build/Release/libnut.node" \
          "$UNPACKED_DST/node_modules/@nut-tree/libnut-linux/build/Release/libnut.node"
    # @earendil-works/pi-tui native (从 asar 内 inject)
    if [ -d "$LINUX_NATIVE_DIR/@earendil-works/pi-tui/native/linux" ]; then
        mkdir -p "$UNPACKED_DST/node_modules/@earendil-works/pi-tui/native"
        cp -rf "$LINUX_NATIVE_DIR/@earendil-works/pi-tui/native/linux" \
              "$UNPACKED_DST/node_modules/@earendil-works/pi-tui/native/"
    fi
    # ripgrep-linux binary (npm @vscode/ripgrep-linux-x64)
    if [ -d "$LINUX_NATIVE_DIR/@vscode/ripgrep-linux-x64" ]; then
        mkdir -p "$UNPACKED_DST/node_modules/@vscode"
        cp -rf "$LINUX_NATIVE_DIR/@vscode/ripgrep-linux-x64" \
              "$UNPACKED_DST/node_modules/@vscode/"
    fi
    # jszip (peer dep for better-sqlite3 v12)
    if [ -d "$LINUX_NATIVE_DIR/jszip" ]; then
        cp -rf "$LINUX_NATIVE_DIR/jszip" "$UNPACKED_DST/node_modules/"
    fi
    echo "[deb] ✓ Linux natives injected: $(find $UNPACKED_DST -name "*.node" -type f | wc -l) .node files"
else
    echo "[WARN] 找不到 $LINUX_NATIVE_DIR/better-sqlite3/build/Release/, 跳过 native 注入"
    echo "       (如首次构建, 请先跑 scripts/build-linux-gui.sh)"
fi

# === mmx-patch: 装 libfmod_shim.so (解决 fmod@GLIBC_2.38 缺失问题) ===
# better-sqlite3 v12 rebuild 后会引用 fmod@GLIBC_2.38 (glibc 2.38 改了 fmod 实现)
# focal (GLIBC 2.31) 和 jammy (GLIBC 2.35) 系统 libm 都没这个 versioned symbol
# 装 shim 提供 fmod@GLIBC_2.38 (C99 简单实现), run.sh 会 LD_PRELOAD 它
SHIM_SRC="$PROJECT_ROOT/dist-lib/libfmod_shim.so"
if [ -f "$SHIM_SRC" ]; then
    cp -f "$SHIM_SRC" "$PKG_ROOT/opt/MiniMax Code/libfmod_shim.so"
    chmod 755 "$PKG_ROOT/opt/MiniMax Code/libfmod_shim.so"
    echo "[deb] ✓ libfmod_shim.so 装到 /opt/MiniMax Code/"
else
    echo "[WARN] 找不到 $SHIM_SRC, 没装 shim (旧版系统可能跑不起来)"
fi

# 删 win32 平台 native binding（Linux 上不需要, 节省空间）
rm -rf "$UNPACKED_DST/node_modules/@nut-tree/libnut-win32"
rm -rf "$UNPACKED_DST/node_modules/@earendil-works/pi-tui/native/win32" 2>/dev/null
rm -rf "$UNPACKED_DST/node_modules/node-pty/prebuilds/win32-x64"
rm -rf "$UNPACKED_DST/node_modules/@vscode/ripgrep-win32-x64" 2>/dev/null
rm -rf "$UNPACKED_DST/node_modules/node-screenshots-win32-x64-msvc" 2>/dev/null
# 删 win32 平台 better-sqlite3 DLL (避免被误加载, 强制走 Linux 版)
rm -rf "$UNPACKED_DST/node_modules/better-sqlite3/build/Release/obj" 2>/dev/null
# 留 Windows installer scripts (dmg/nsis) 等不动 — 跟安装无关
chmod -R go+rX "$PKG_ROOT/opt/MiniMax Code/app"

# ===== 3) /opt/MiniMax Code/run.sh — 启动脚本 =====
cat > "$PKG_ROOT/opt/MiniMax Code/run.sh" <<'EOF'
#!/usr/bin/env bash
# MiniMax Code Linux 启动脚本 (deb 包内)
set -e
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELECTRON_BIN="$APP_DIR/electron/dist/electron"
APP_ASAR="$APP_DIR/app/app-64/resources/app.asar"

# 用户数据目录 (per-user)
USER_DATA="${MMX_USER_DATA:-$HOME/.config/MiniMax-Code}"
mkdir -p "$USER_DATA"

# === mmx-patch: LD_PRELOAD libfmod_shim.so 解决 fmod@GLIBC_2.38 缺失 ===
# better-sqlite3 v12 在 noble (GLIBC 2.39) rebuild 后会要 fmod@GLIBC_2.38
# focal (2.31) / jammy (2.35) 系统 libm.so.6 没这个 versioned symbol
# shim 提供兼容实现, LD_PRELOAD 会被 electron + 所有子进程继承
# 注意: APP_DIR 含空格 ("/opt/MiniMax Code/"), 必须 quotes
SHIM_PATH="$APP_DIR/libfmod_shim.so"
if [ -f "$SHIM_PATH" ]; then
    # 用 : 分隔, 但每个 entry 都要 quotes (LD_PRELOAD 是 colon-separated 但不支持 quoting)
    # 解法: symlink 到无空格路径
    SHIM_LINK="/tmp/minimax-fmod-shim.so"
    cp -f "$SHIM_PATH" "$SHIM_LINK" 2>/dev/null || true
    if [ -f "$SHIM_LINK" ]; then
        export LD_PRELOAD="$SHIM_LINK${LD_PRELOAD:+:$LD_PRELOAD}"
    fi
fi

# 环境变量
export NODE_OPTIONS="${NODE_OPTIONS:---no-deprecation}"
export ELECTRON_ENABLE_LOGGING=1
export ELECTRON_DISABLE_SECURITY_WARNINGS=1

# 启动
exec "$ELECTRON_BIN" \
  --no-sandbox \
  --disable-gpu \
  --in-process-gpu \
  --user-data-dir="$USER_DATA" \
  "$APP_ASAR" "$@"
EOF
chmod 755 "$PKG_ROOT/opt/MiniMax Code/run.sh"

# ===== 4) /opt/MiniMax Code/install-protocol-handler.sh — protocol 注册 =====
cp "$SCRIPT_DIR/install-protocol-handler.sh" "$PKG_ROOT/opt/MiniMax Code/install-protocol-handler.sh"
chmod 755 "$PKG_ROOT/opt/MiniMax Code/install-protocol-handler.sh"
# 修 patch 让 protocol handler 指向 /opt/MiniMax Code/ 而不是 PROJECT_ROOT
python3 <<PYEOF
p = "$PKG_ROOT/opt/MiniMax Code/install-protocol-handler.sh"
s = open(p).read()
s = s.replace(
    'PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"',
    'PROJECT_ROOT="/opt/MiniMax Code"'
)
s = s.replace(
    'APP_ASAR="$PROJECT_ROOT/unpacked/app-64/resources/app.asar"',
    'APP_ASAR="$PROJECT_ROOT/app/app-64/resources/app.asar"'
)
s = s.replace(
    'ICON_PATH="$PROJECT_ROOT/unpacked/app-64/resources/resources/icon.png"',
    'ICON_PATH="$PROJECT_ROOT/app/app-64/resources/resources/icon.png"'
)
open(p, "w").write(s)
PYEOF

# ===== 5) /opt/MiniMax Code/README.md =====
cp "$PROJECT_ROOT/README-LINUX.md" "$PKG_ROOT/opt/MiniMax Code/README.md"
cp "$PROJECT_ROOT/README-LINUX.md" "$PKG_ROOT/usr/share/doc/${PACKAGE_NAME}/README.md"
gzip -9 -f "$PKG_ROOT/usr/share/doc/${PACKAGE_NAME}/README.md"

# ===== 6) /usr/bin/minimax-code — wrapper =====
cat > "$PKG_ROOT/usr/bin/minimax-code" <<'EOF'
#!/usr/bin/env bash
# MiniMax Code Linux GUI client
exec /opt/MiniMax\ Code/run.sh "$@"
EOF
chmod 755 "$PKG_ROOT/usr/bin/minimax-code"

# ===== 7) /usr/share/applications/minimax-code.desktop =====
# 重要: Exec 路径含空格, 必须用双引号包起来, 符合 freedesktop 规范
# 否则 GioUnix.DesktopAppInfo.new_from_filename() 返回 NULL
cat > "$PKG_ROOT/usr/share/applications/minimax-code.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${APP_DISPLAY_NAME}
GenericName=AI Coding Assistant
Comment=MiniMax Code Desktop AI Agent
Exec="/opt/MiniMax Code/run.sh" %u
Icon=minimax-code
Terminal=false
NoDisplay=false
Categories=Development;
MimeType=x-scheme-handler/minimax-cn;
StartupNotify=true
StartupWMClass=MiniMax Code
EOF

# ===== 8) /usr/share/icons/hicolor/ — 多尺寸 PNG =====
echo "[deb] 装 hicolor 图标"
for sz in 16 32 48 64 128 256 512; do
  dst="$PKG_ROOT/usr/share/icons/hicolor/${sz}x${sz}/apps"
  mkdir -p "$dst"
  convert "$ICON_PNG_SRC" -resize ${sz}x${sz} "$dst/minimax-code.png" 2>/dev/null || \
    cp "$ICON_PNG_SRC" "$dst/minimax-code.png"
done
mkdir -p "$PKG_ROOT/usr/share/icons/hicolor/scalable/apps"
cp "$ICON_PNG_SRC" "$PKG_ROOT/usr/share/icons/hicolor/scalable/apps/minimax-code.png"

# ===== 9) DEBIAN/control =====
INSTALLED_SIZE=$(du -sk "$PKG_ROOT" | awk '{print $1}')
cat > "$PKG_ROOT/DEBIAN/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Description: ${DESCRIPTION}
 ${APP_DISPLAY_NAME} is a desktop AI coding assistant. This package contains
 the Linux GUI client built from the Windows NSIS installer via the
 @mmx-agent/electron v${VERSION} build, modified to run on Linux Electron 43
 with native Linux bindings (better-sqlite3, node-pty, @nut-tree/libnut, ripgrep).
Section: devel
Priority: optional
Depends: libc6 (>= 2.31), libasound2t64 (>= 1.0.16) | libasound2 (>= 1.0.16), libatk1.0-0t64 | libatk1.0-0 (>= 2.35.1), libatk-bridge2.0-0t64 | libatk-bridge2.0-0 (>= 2.5.3), libatspi2.0-0t64 | libatspi2.0-0 (>= 2.1.0), libcairo2 (>= 1.14.0), libcups2t64 | libcups2 (>= 1.6.0), libdbus-1-3 (>= 1.9.14), libexpat1 (>= 2.1.0), libgbm1 (>= 21.2.0), libgcc-s1 (>= 3.0), libglib2.0-0t64 | libglib2.0-0 (>= 2.37.3), libnss3 (>= 3.26), libpango-1.0-0 (>= 1.22.0), libpangocairo-1.0-0 (>= 1.22.0), libxcomposite1 (>= 1:0.4.4-2), libxdamage1 (>= 1:1.1.4-1+b1), libxext6, libxfixes3 (>= 1:5.0.1-2), libxkbcommon0 (>= 0.4.1), libxrandr2 (>= 2:1.2.99.2-1), libxshmfence1, libdrm2 (>= 2.4.107), libnspr4 (>= 2:4.35), libnotify4 (>= 0.7.7), libsecret-1-0 (>= 0.20), libxss1, libxtst6
Recommends: libappindicator3-1
Suggests: apt-transport-https
Installed-Size: ${INSTALLED_SIZE}
EOF

# ===== 9.5) DEBIAN/preinst — 装前自动补依赖 (关键: dpkg -i 失败时只有 preinst 会跑) =====
# mmx-patch v2: 用 apt-get install -f 解决所有未满足依赖 (包括 version 不匹配)
# 之前只检查 dpkg -s, 漏掉了 "装了但版本太老" 的情况 (focal libatk 2.35.1 < 要求 2.36.0)
cat > "$PKG_ROOT/DEBIAN/preinst" <<'EOF'
#!/bin/sh
set +e  # 不要让单个错误中止整个 preinst
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MiniMax Code: 准备安装环境 (需要 sudo / root 权限)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if ! command -v apt-get >/dev/null 2>&1; then
    echo "⚠ 未检测到 apt-get, 跳过自动依赖安装 (非 Debian/Ubuntu 系统)"
    echo "  请手动确认: libnss3 libdrm2 libnotify4 libgbm1 libxkbcommon0 等已装"
    exit 0
fi

# 1) apt-get update (让 apt 知道最新包版本)
echo "▶ apt-get update ..."
apt-get update 2>&1 | tail -3

# 2) 尝试安装完整依赖列表 (用 alternates 让 apt 自动选 t64 vs 旧版)
DEPS="libnss3 libnspr4 libdrm2 libxkbcommon0 libgbm1 libnotify4 libsecret-1-0 \
      libxss1 libxtst6 libcairo2 libpango-1.0-0 libpangocairo-1.0-0 \
      libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxshmfence1 \
      libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 libcups2 libdbus-1-3 \
      libexpat1 libglib2.0-0 libxext6 libasound2 libgtk-3-0 \
      libxcb-dri3-0 libcairo-gobject2 fonts-liberation"
echo "▶ apt-get install -y $DEPS ..."
# shellcheck disable=SC2086
if apt-get install -y --no-install-recommends $DEPS 2>&1 | tail -10; then
    echo "✓ 依赖安装完成"
else
    echo "⚠ 直接安装失败, 尝试 apt-get install -f -y 修复未满足依赖 ..."
    apt-get install -f -y 2>&1 | tail -5
fi

# 3) 兜底: 用 apt-get -f install 再扫一遍
dpkg --configure -a 2>&1 | tail -3

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MiniMax Code: 依赖检查完成, 继续安装"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0
EOF
chmod 755 "$PKG_ROOT/DEBIAN/preinst"

# ===== 10) DEBIAN/postinst — 注册 protocol + update icon cache =====
cat > "$PKG_ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
# === mmx-patch: 检查上游依赖完整性, 缺了自动 apt 装 ===
# 解决: 用户 dpkg -i 装的时, 缺少 libdrm2/libnotify4 等, electron 启动会 SIGSEGV
# 解决: 这里检测 + 自动调 apt-get install -f 把缺的包装上
DEPS_MISSING=""
for dep in libnss3 libnspr4 libdrm2 libxkbcommon0 libgbm1 libnotify4 libsecret-1-0 libxss1 libxtst6 libcairo2 libpango-1.0-0; do
    if ! dpkg -s "$dep" >/dev/null 2>&1; then
        DEPS_MISSING="$DEPS_MISSING $dep"
    fi
done
if [ -n "$DEPS_MISSING" ]; then
    echo "MiniMax Code: 检测到上游依赖不全:$DEPS_MISSING"
    echo "正在尝试自动安装 (需要网络 + sudo) ..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq 2>/dev/null || true
        # shellcheck disable=SC2086
        if apt-get install -y --no-install-recommends $DEPS_MISSING 2>&1 | tail -5; then
            echo "✓ 依赖装好"
        else
            echo "⚠ 自动装依赖失败, 请手动跑: sudo apt-get install -f"
        fi
    fi
fi
# === end mmx-patch ===

# Update icon cache
for sz in 16 32 48 64 128 256 512 scalable; do
  if [ -d "/usr/share/icons/hicolor/${sz}/apps" ]; then
    gtk-update-icon-cache -f -t "/usr/share/icons/hicolor/${sz}" 2>/dev/null || true
  fi
done
# Update desktop database
update-desktop-database /usr/share/applications 2>/dev/null || true
# Refresh mimeapps
xdg-mime default minimax-code.desktop x-scheme-handler/minimax-cn 2>/dev/null || true
echo ""
echo "✅ MiniMax Code installed. Run with: minimax-code"
echo "   or find in your application menu."
echo ""
echo "ℹ 如果启动报 libxxx.so 缺失, 跑: sudo apt-get install -f"
exit 0
EOF
chmod 755 "$PKG_ROOT/DEBIAN/postinst"

# ===== 11) DEBIAN/prerm — 清理 =====
cat > "$PKG_ROOT/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
case "$1" in
  remove|purge)
    update-desktop-database /usr/share/applications 2>/dev/null || true
    for sz in 16 32 48 64 128 256 512 scalable; do
      gtk-update-icon-cache -f -t "/usr/share/icons/hicolor/${sz}" 2>/dev/null || true
    done
    ;;
esac
exit 0
EOF
chmod 755 "$PKG_ROOT/DEBIAN/prerm"

# ===== 12) DEBIAN/conffiles =====
cat > "$PKG_ROOT/DEBIAN/conffiles" <<'EOF'
/opt/MiniMax Code/run.sh
/opt/MiniMax Code/install-protocol-handler.sh
EOF

# ===== 13) build .deb =====
mkdir -p "$DIST_DIR"
echo "[deb] 打包 .deb ..."
# === mmx-patch: 用 sync + dpkg-deb (不用 fakeroot 避免 zstd checksum bug) ===
# fakeroot 会写 fake mtimes/owners, 偶尔和 zstd 压缩不兼容
# 直接 dpkg-deb --build 用本机 root, 一次写完
sync
# 先确保 PKG_ROOT 没有 uncommitted writes
find "$PKG_ROOT" -type f -exec touch -d "2024-01-01 00:00:00" {} \; 2>/dev/null || true
find "$PKG_ROOT" -type d -exec touch -d "2024-01-01 00:00:00" {} \; 2>/dev/null || true
dpkg-deb --build --root-owner-group "$PKG_ROOT" "$DIST_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb" 2>&1 | tail -3
# 验证
echo "[deb] 验证 deb 完整性..."
if dpkg-deb -I "$DIST_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb" >/dev/null 2>&1; then
  echo "[deb] ✓ 完整"
else
  echo "[deb] ✗ 坏, 重打"
  fakeroot dpkg-deb --build --root-owner-group "$PKG_ROOT" "$DIST_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb" 2>&1 | tail -3
fi

echo ""
echo "✅ deb 打包完成: $DIST_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"
ls -lh "$DIST_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"
echo ""
echo "安装: sudo dpkg -i $DIST_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"
echo "卸载: sudo dpkg --purge ${PACKAGE_NAME}"
