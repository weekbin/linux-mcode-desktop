#!/usr/bin/env bash
# install-protocol-handler.sh — 在 Linux 上注册 minimax-cn:// URL scheme handler
#
# 给 dev 模式用 (从 build 目录直接跑, 不装 deb). 装 deb 的话 postinst 已经
# 写了 /usr/share/applications/minimax-code.desktop, 不需要跑这个.
#
# 写入:
#   ~/.local/share/applications/minimax-linux.desktop
#   ~/.local/share/applications/mimeapps.list (append)
#   ~/.local/share/icons/hicolor/*/apps/minimax-linux.png
#
# 让浏览器 OAuth callback `minimax-cn://...?code=xxx` 能唤起 dev 模式的 MiniMax Code
#
# Idempotent — 可以重复跑

set -e

# ===== 路径自定位 (BASH_SOURCE 不用 hardcode 开发者机器路径) =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 假设目录结构: scripts/install-protocol-handler.sh
# 需要的: <repo>/unpacked/app-64/resources/app.asar  +  <repo>/electron/dist/electron
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_ASAR="$PROJECT_ROOT/unpacked/app-64/resources/app.asar"
# ELEC43_DIR 可覆盖, 否则用 repo 自带的 (如果有)
if [ -n "${ELEC43_DIR:-}" ]; then
    ELEC_BIN="$ELEC43_DIR/dist/electron"
elif [ -x "$PROJECT_ROOT/electron/dist/electron" ]; then
    ELEC_BIN="$PROJECT_ROOT/electron/dist/electron"
else
    echo "[ERROR] 找不到 electron 二进制." >&2
    echo "  1) 把 electron 43 解到 <repo>/electron/ 目录" >&2
    echo "  2) 或设 ELEC43_DIR 环境变量指向 electron 解压目录" >&2
    exit 1
fi

DESKTOP_FILE="$HOME/.local/share/applications/minimax-linux.desktop"
MIMEAPPS_FILE="$HOME/.local/share/applications/mimeapps.list"
ICON_NAME="minimax-linux"

# 协议名（必须和 dist/main/modules/deeplink/index.js 里的 PROTOCOL_NAME 一致）
# asar 动态判断: zh→minimax-cn, en→minimax, 还有 -test/-staging 变种
# 这里默认 zh (国内版线上), 可用 PROTOCOL_NAME 环境变量覆盖
PROTOCOL_NAME="${PROTOCOL_NAME:-minimax-cn}"
MIME_TYPE="x-scheme-handler/${PROTOCOL_NAME}"

# 检查依赖
if [ ! -x "$ELEC_BIN" ]; then
  echo "[ERROR] electron 二进制不可执行: $ELEC_BIN" >&2
  echo "  chmod +x $ELEC_BIN" >&2
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
    mkdir -p "$HICOLOR/${sz}x${sz}/apps" 2>/dev/null
    cp "$ICON_SOURCE" "$HICOLOR/${sz}x${sz}/apps/${ICON_NAME}.png" 2>/dev/null
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
EXEC_LINE="\"$ELEC_BIN\" --no-sandbox --disable-gpu --in-process-gpu --user-data-dir=\${MMX_USER_DATA:-/tmp/mmx-linux-userdata} \"$APP_ASAR\" %u"

# 写 .desktop
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=MiniMax Code (dev)
GenericName=AI Coding Assistant
Comment=Open ${PROTOCOL_NAME}:// deep links in MiniMax Code Linux (dev)
Exec=$EXEC_LINE
Icon=$ICON_NAME
Terminal=false
NoDisplay=false
Categories=Development;
MimeType=$MIME_TYPE;
StartupNotify=true
StartupWMClass=mmx-agent-electron
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
echo "   现在从浏览器点 ${PROTOCOL_NAME}://... 链接会启动 MiniMax Code (dev)"
echo "   如要卸载: rm $DESKTOP_FILE && 删 $MIMEAPPS_FILE 里的 x-scheme-handler/$PROTOCOL_NAME 行"
