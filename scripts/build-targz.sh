#!/usr/bin/env bash
# build-targz.sh — 打 tar.gz 包（兜底，给非 Debian 系统用）
#
# 输出: dist/minimax-code_<version>_linux-x64.tar.gz
#
# 解压后:
#   ./minimax-code-linux/install.sh  # 装到 ~/.local + ~/.local/share
#   ./minimax-code-linux/bin/minimax-code  # 启动 wrapper
#   ./minimax-code-linux/app/         # app.asar + resources
#   ./minimax-code-linux/electron/    # Linux Electron 43
#   ./minimax-code-linux/share/       # .desktop + icons
#
# install.sh 不会 root-required, 写到 ~/.local/bin + ~/.local/share

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
WORK_DIR="/tmp/minimax-code-targz-build"
PACKAGE_NAME="minimax-code"
APP_DISPLAY_NAME="MiniMax Code"
VERSION="3.0.67-inside.44"
ARCH="linux-x64"
PACKAGE_DIR="minimax-code-${VERSION}-${ARCH}"

# 源
ELEC43_SRC="${ELEC43_DIR:-/home/weekbin/Works/repositories/orca/node_modules/.pnpm/electron@43.1.0/node_modules/electron}"
APP_ASAR_SRC="$PROJECT_ROOT/unpacked/app-64"
ICON_PNG_SRC="$PROJECT_ROOT/unpacked/app-64/resources/resources/icon.png"

# 检查
if [ ! -x "$ELEC43_SRC/dist/electron" ]; then
  echo "[ERROR] 找不到 Linux Electron 43: $ELEC43_SRC" >&2
  exit 1
fi
if [ ! -d "$APP_ASAR_SRC" ]; then
  echo "[ERROR] 找不到 app.asar: $APP_ASAR_SRC" >&2
  exit 1
fi
if [ ! -f "$ICON_PNG_SRC" ]; then
  echo "[ERROR] 找不到 icon.png: $ICON_PNG_SRC" >&2
  exit 1
fi

echo "[tgz] 准备 build dir: $WORK_DIR"
mavis-trash "$WORK_DIR" 2>/dev/null || rm -rf "$WORK_DIR" 2>/dev/null || true
mkdir -p "$WORK_DIR/$PACKAGE_DIR"

STAGE="$WORK_DIR/$PACKAGE_DIR"

# ===== 1) electron/ =====
echo "[tgz] 复制 Electron 43"
cp -r "$ELEC43_SRC" "$STAGE/electron-tmp"
mv "$STAGE/electron-tmp" "$STAGE/electron"
chmod -R go+rX "$STAGE/electron"

# ===== 2) app/ — 只复制 resources/ (asar + icons + unpacked native) =====
echo "[tgz] 复制 app resources"
mkdir -p "$STAGE/app"
mkdir -p "$STAGE/app/app-64"
cp -r "$APP_ASAR_SRC/resources" "$STAGE/app/app-64/resources"
rm -f "$STAGE/app/app-64/resources/app.asar.orig"
rm -f "$STAGE/app/app-64/resources/elevate.exe"
# 删 win32 平台 native binding
rm -rf "$STAGE/app/app-64/resources/app.asar.unpacked/node_modules/@nut-tree/libnut-win32"
rm -rf "$STAGE/app/app-64/resources/app.asar.unpacked/node_modules/@earendil-works/pi-tui/native/win32"
rm -rf "$STAGE/app/app-64/resources/app.asar.unpacked/node_modules/node-pty/prebuilds/win32-x64"
rm -rf "$STAGE/app/app-64/resources/app.asar.unpacked/node_modules/@vscode/ripgrep-win32-x64"
chmod -R go+rX "$STAGE/app"

# ===== 3) bin/minimax-code =====
mkdir -p "$STAGE/bin"
cat > "$STAGE/bin/minimax-code" <<EOF
#!/usr/bin/env bash
# MiniMax Code Linux GUI client
APP_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
exec "\$APP_DIR/electron/dist/electron" \\
  --no-sandbox \\
  --disable-gpu \\
  --in-process-gpu \\
  --user-data-dir="\${MMX_USER_DATA:-\$HOME/.config/MiniMax-Code}" \\
  "\$APP_DIR/app/app-64/resources/app.asar" "\$@"
EOF
chmod 755 "$STAGE/bin/minimax-code"

# ===== 4) share/ — .desktop + icons =====
mkdir -p "$STAGE/share/applications"
mkdir -p "$STAGE/share/icons/hicolor"
# freedesktop 规范: Exec 路径含空格必须用双引号
cat > "$STAGE/share/applications/minimax-code.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${APP_DISPLAY_NAME}
GenericName=AI Coding Assistant
Comment=MiniMax Code Desktop AI Agent
Exec="\$APP_DIR/bin/minimax-code" %u
Icon=minimax-code
Terminal=false
Categories=Development;
MimeType=x-scheme-handler/minimax-cn;
StartupNotify=true
StartupWMClass=MiniMax Code
EOF
# 多尺寸 PNG
for sz in 16 32 48 64 128 256 512; do
  dst="$STAGE/share/icons/hicolor/${sz}x${sz}/apps"
  mkdir -p "$dst"
  convert "$ICON_PNG_SRC" -resize ${sz}x${sz} "$dst/minimax-code.png" 2>/dev/null || \
    cp "$ICON_PNG_SRC" "$dst/minimax-code.png"
done
mkdir -p "$STAGE/share/icons/hicolor/scalable/apps"
cp "$ICON_PNG_SRC" "$STAGE/share/icons/hicolor/scalable/apps/minimax-code.png"

# ===== 5) install.sh — user-level install =====
cat > "$STAGE/install.sh" <<'INSTALL_EOF'
#!/usr/bin/env bash
# MiniMax Code Linux — user-level installer
# 写到 ~/.local/bin 和 ~/.local/share，不需要 root
set -e

APP_DISPLAY_NAME="MiniMax Code"
PACKAGE_NAME="minimax-code"

# 默认装到 ~/.local，但允许 PREFIX 覆盖
PREFIX="${PREFIX:-$HOME/.local}"
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 用户可能想装到 /opt 而不是 ~/.local (root 装)
if [ "$PREFIX" = "/usr" ] || [ "$PREFIX" = "/usr/local" ]; then
  SUDO="sudo"
  SUDO_N=""
else
  SUDO=""
  SUDO_N="(user-level)"
fi

echo "=== Installing MiniMax Code (${SUDO_N:-system}) ==="
echo "  PREFIX=$PREFIX"
echo "  STAGE=$STAGE_DIR"
echo ""

# 1) 复制主目录
echo "[1/5] 复制 $PREFIX/share/$PACKAGE_NAME/ ..."
$SUDO mkdir -p "$PREFIX/share/$PACKAGE_NAME"
$SUDO cp -r "$STAGE_DIR/app" "$PREFIX/share/$PACKAGE_NAME/"
$SUDO cp -r "$STAGE_DIR/electron" "$PREFIX/share/$PACKAGE_NAME/"
$SUDO cp "$STAGE_DIR/share/applications/$PACKAGE_NAME.desktop" \
         "$PREFIX/share/applications/$PACKAGE_NAME.desktop" 2>/dev/null || true
$SUDO cp -r "$STAGE_DIR/share/icons"/* "$PREFIX/share/icons/" 2>/dev/null || true

# 2) bin/ wrapper
echo "[2/5] 复制 wrapper 到 $PREFIX/bin/ ..."
$SUDO mkdir -p "$PREFIX/bin"
$SUDO tee "$PREFIX/bin/$PACKAGE_NAME" > /dev/null <<WRAPPER_EOF
#!/usr/bin/env bash
exec "$PREFIX/share/$PACKAGE_NAME/electron/dist/electron" \\
  --no-sandbox \\
  --disable-gpu \\
  --in-process-gpu \\
  --user-data-dir="\${MMX_USER_DATA:-\$HOME/.config/MiniMax-Code}" \\
  "$PREFIX/share/$PACKAGE_NAME/app/app-64/resources/app.asar" "\$@"
WRAPPER_EOF
$SUDO chmod 755 "$PREFIX/bin/$PACKAGE_NAME"

# 3) 修 .desktop 的 Exec 指向装好的 wrapper (freedesktop 规范: 引号包路径)
if [ -f "$PREFIX/share/applications/$PACKAGE_NAME.desktop" ]; then
  $SUDO sed -i "s|^Exec=.*|Exec=\"$PREFIX/bin/$PACKAGE_NAME\" %u|" \
            "$PREFIX/share/applications/$PACKAGE_NAME.desktop"
fi

# 4) 注册 minimax-cn:// protocol
echo "[3/5] 注册 minimax-cn:// protocol handler ..."
DESKTOP_FILE="$PREFIX/share/applications/$PACKAGE_NAME.desktop"
if command -v xdg-mime >/dev/null 2>&1; then
  $SUDO xdg-mime default "$PACKAGE_NAME.desktop" x-scheme-handler/minimax-cn 2>/dev/null || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  $SUDO update-desktop-database "$PREFIX/share/applications/" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  for sz in 16 32 48 64 128 256 512 scalable; do
    $SUDO gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor/${sz}" 2>/dev/null || true
  done
fi

# 5) 写 README
echo "[4/5] 写文档到 $PREFIX/share/doc/$PACKAGE_NAME/"
$SUDO mkdir -p "$PREFIX/share/doc/$PACKAGE_NAME"
[ -f "$STAGE_DIR/README.md" ] && $SUDO cp "$STAGE_DIR/README.md" "$PREFIX/share/doc/$PACKAGE_NAME/" 2>/dev/null || true

echo ""
echo "[5/5] ✅ 装好了"
echo ""
echo "启动: $PACKAGE_NAME"
echo "或者: $PREFIX/bin/$PACKAGE_NAME"
echo ""
echo "卸载: rm -rf $PREFIX/bin/$PACKAGE_NAME $PREFIX/share/$PACKAGE_NAME $PREFIX/share/applications/$PACKAGE_NAME.desktop"
INSTALL_EOF
chmod 755 "$STAGE/install.sh"

# ===== 6) uninstall.sh =====
cat > "$STAGE/uninstall.sh" <<'UNINSTALL_EOF'
#!/usr/bin/env bash
# MiniMax Code Linux — uninstaller
PREFIX="${PREFIX:-$HOME/.local}"
PACKAGE_NAME="minimax-code"
SUDO=""
[ "$PREFIX" = "/usr" ] || [ "$PREFIX" = "/usr/local" ] && SUDO="sudo"

echo "卸载 MiniMax Code from $PREFIX ..."
$SUDO rm -f "$PREFIX/bin/$PACKAGE_NAME"
$SUDO rm -rf "$PREFIX/share/$PACKAGE_NAME"
$SUDO rm -f "$PREFIX/share/applications/$PACKAGE_NAME.desktop"
$SUDO rm -f "$PREFIX/share/icons/hicolor/"{16,32,48,64,128,256,512}"x"{16,32,48,64,128,256,512}"/apps/$PACKAGE_NAME.png"
$SUDO rm -f "$PREFIX/share/icons/hicolor/scalable/apps/$PACKAGE_NAME.png"
if command -v update-desktop-database >/dev/null 2>&1; then
  $SUDO update-desktop-database "$PREFIX/share/applications/" 2>/dev/null || true
fi
echo "✅ 卸载完成"
UNINSTALL_EOF
chmod 755 "$STAGE/uninstall.sh"

# ===== 7) README.md =====
cp "$PROJECT_ROOT/README-LINUX.md" "$STAGE/README.md"

# ===== 8) tar.gz =====
mkdir -p "$DIST_DIR"
echo "[tgz] 打包 ..."
cd "$WORK_DIR"
tar -czf "$DIST_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.tar.gz" "$PACKAGE_DIR/" 2>&1 | tail -3

# 也做一个 .tar (无压缩) — 更快解压
echo "[tgz] 打包 (无压缩) ..."
tar -cf "$DIST_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.tar" "$PACKAGE_DIR/" 2>&1 | tail -3

echo ""
echo "✅ tar 包完成:"
ls -lh "$DIST_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}".tar* 2>/dev/null
echo ""
echo "用法:"
echo "  tar -xzf $DIST_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.tar.gz"
echo "  cd $PACKAGE_DIR"
echo "  ./install.sh          # user-level 装到 ~/.local"
echo "  PREFIX=/opt ./install.sh  # 装到 /opt (需要 root)"
echo "  ./bin/minimax-code    # 直接跑（不 install）"
