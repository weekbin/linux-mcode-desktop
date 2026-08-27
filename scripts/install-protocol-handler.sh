#!/usr/bin/env bash
# install-protocol-handler.sh — 在 Linux 上注册 minimax-cn:// URL scheme handler
#
# 写入:
#   ~/.local/share/applications/minimax-linux.desktop
#   ~/.local/share/applications/mimeapps.list (append)
#
# 让浏览器 OAuth callback `minimax-cn://...?code=xxx` 能唤起 MiniMax Code Linux GUI
#
# Idempotent — 可以重复跑

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_ASAR="$PROJECT_ROOT/unpacked/app-64/resources/app.asar"
ELEC_BIN="${ELEC43_DIR:-/home/weekbin/Works/repositories/orca/node_modules/.pnpm/electron@43.1.0/node_modules/electron}/dist/electron"

DESKTOP_FILE="$HOME/.local/share/applications/minimax-linux.desktop"
MIMEAPPS_FILE="$HOME/.local/share/applications/mimeapps.list"
# Icon: 用 stock name 让 hicolor theme 解析（install-icons.sh 会装到 ~/.local/share/icons/hicolor/）
ICON_NAME="minimax-linux"
ICON_PATH="$HOME/.local/share/icons/hicolor/256x256/apps/${ICON_NAME}.png"

# 协议名（必须和 dist/main/modules/deeplink/index.js 里的 PROTOCOL_NAME 一致）
PROTOCOL_NAME="minimax-cn"
MIME_TYPE="x-scheme-handler/${PROTOCOL_NAME}"

# 检查依赖
if [ ! -x "$ELEC_BIN" ]; then
  echo "[ERROR] 找不到 Electron: $ELEC_BIN" >&2
  exit 1
fi
if [ ! -f "$APP_ASAR" ]; then
  echo "[ERROR] 找不到 app.asar: $APP_ASAR" >&2
  echo "  请先跑 scripts/build-linux-gui.sh" >&2
  exit 1
fi

# 装 hicolor 图标（freedesktop 标准，让 taskbar/dock/launcher 显示）
ICON_SOURCE="$PROJECT_ROOT/unpacked/app-64/resources/resources/icon.png"
if [ -f "$ICON_SOURCE" ]; then
  HICOLOR="$HOME/.local/share/icons/hicolor"
  for sz in 16 32 48 64 128 256 512 scalable; do
    mkdir -p "$HICOLOR/${sz}/apps"
    cp "$ICON_SOURCE" "$HICOLOR/${sz}/apps/${ICON_NAME}.png"
  done
  gtk-update-icon-cache -f -t "$HICOLOR" 2>/dev/null && \
    echo "[install] 图标装到 hicolor theme: $HICOLOR" || \
    echo "[install] 图标装到 hicolor theme (cache skip)"
else
  echo "[install] (warn) 找不到 $ICON_SOURCE，跳过图标安装"
fi

mkdir -p "$(dirname "$DESKTOP_FILE")"

# Exec= 用 %u 让 xdg-open 把 URL 作为唯一参数传
# 路径加引号处理空格
EXEC_LINE="$ELEC_BIN --no-sandbox --disable-gpu --in-process-gpu --user-data-dir=${MMX_USER_DATA:-/tmp/mmx-linux-userdata} \"$APP_ASAR\" %u"

# 写 .desktop
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=MiniMax Code
GenericName=AI Coding Assistant
Comment=Open minimax-cn:// deep links in MiniMax Code Linux
Exec=$EXEC_LINE
Icon=$ICON_NAME
Terminal=false
NoDisplay=false
Categories=Development;
MimeType=$MIME_TYPE;
StartupNotify=true
StartupWMClass=MiniMax Code
EOF
echo "[install] 写 $DESKTOP_FILE"

# 在 mimeapps.list 加 association (idempotent)
if [ ! -f "$MIMEAPPS_FILE" ]; then
  mkdir -p "$(dirname "$MIMEAPPS_FILE")"
  touch "$MIMEAPPS_FILE"
fi

# 检查是否已经有这行
if grep -q "^${MIME_TYPE}=" "$MIMEAPPS_FILE" 2>/dev/null; then
  # 已有，更新 target
  sed -i "s|^${MIME_TYPE}=.*|${MIME_TYPE}=minimax-linux.desktop|" "$MIMEAPPS_FILE"
  echo "[install] 更新 $MIMEAPPS_FILE: $MIME_TYPE=minimax-linux.desktop"
else
  # 加 [Default Applications] section 如果没
  if ! grep -q "^\[Default Applications\]" "$MIMEAPPS_FILE" 2>/dev/null; then
    echo "" >> "$MIMEAPPS_FILE"
    echo "[Default Applications]" >> "$MIMEAPPS_FILE"
  fi
  echo "${MIME_TYPE}=minimax-linux.desktop" >> "$MIMEAPPS_FILE"
  echo "[install] 添加 $MIMEAPPS_FILE: $MIME_TYPE=minimax-linux.desktop"
fi

# 刷新 desktop + mime database
update-desktop-database "$HOME/.local/share/applications/" 2>/dev/null && \
  echo "[install] update-desktop-database OK" || \
  echo "[install] (skip) update-desktop-database 不可用，不影响"

# 用 xdg-mime 强制 default
xdg-mime default minimax-linux.desktop "$MIME_TYPE" 2>&1 && \
  echo "[install] xdg-mime default OK" || \
  echo "[install] (skip) xdg-mime 失败，但 mimeapps.list 已更新"

# 验证
echo ""
echo "=== 验证 ==="
echo "xdg-mime query default $MIME_TYPE:"
xdg-mime query default "$MIME_TYPE" 2>&1
echo ""
echo "测试 xdg-open $PROTOCOL_NAME://test:"
xdg-open "$PROTOCOL_NAME://test" 2>&1 | head -3 || true

echo ""
echo "✅ 协议 handler 已注册"
echo "   现在从浏览器点 minimax-cn://... 链接会启动 MiniMax Code Linux"
echo "   如要卸载: rm $DESKTOP_FILE && 删 $MIMEAPPS_FILE 里的 x-scheme-handler/$PROTOCOL_NAME 行"
