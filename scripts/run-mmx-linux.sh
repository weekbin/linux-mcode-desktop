#!/usr/bin/env bash
# run-mmx-linux.sh — 启动 MiniMax Code Linux GUI 客户端
#
# 用法：
#   ./scripts/run-mmx-linux.sh                    # 启动
#   ./scripts/run-mmx-linux.sh --reset            # 重置 user data + 启动
#   ./scripts/run-mmx-linux.sh --verbose          # 详细日志
#
# 依赖：
#   - Linux Electron 43.1.0 (ELEC43_DIR 或默认 orca 仓库路径)
#   - 修好的 app.asar (build-linux-gui.sh 输出)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_ASAR="$PROJECT_ROOT/unpacked/app-64/resources/app.asar"

# Linux Electron 43.1.0
ELEC43_DIR="${ELEC43_DIR:-/home/weekbin/Works/repositories/orca/node_modules/.pnpm/electron@43.1.0/node_modules/electron}"
ELECTRON_BIN="$ELEC43_DIR/dist/electron"

USER_DATA="${MMX_USER_DATA:-/tmp/mmx-linux-userdata}"
LOG_DIR="/tmp/mmx-logs"
LOG_FILE="$LOG_DIR/mmx-electron.log"

# 协议 handler .desktop 路径
DESKTOP_FILE="$HOME/.local/share/applications/minimax-linux.desktop"

# 选项
RESET=0
VERBOSE=0
NO_REGISTER=0
for arg in "$@"; do
  case "$arg" in
    --reset) RESET=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    --no-register) NO_REGISTER=1 ;;
    -h|--help) cat <<'EOF'
用法: run-mmx-linux.sh [options]
  --reset         清除 user-data-dir 重新启动
  --verbose       详细日志
  --no-register   跳过自动注册 minimax-cn:// protocol handler
EOF
      exit 0 ;;
  esac
done

mkdir -p "$LOG_DIR"

# 注册 minimax-cn:// URL scheme handler（OAuth callback 用）
if [ "$NO_REGISTER" != "1" ] && [ ! -f "$DESKTOP_FILE" ]; then
  echo "[run] 首次启动，注册 minimax-cn:// protocol handler ..."
  bash "$SCRIPT_DIR/install-protocol-handler.sh" || \
    echo "[run] (warn) protocol handler 注册失败，可手动跑 scripts/install-protocol-handler.sh"
fi

# 检查
if [ ! -x "$ELECTRON_BIN" ]; then
  echo "[ERROR] 找不到 Linux Electron 43 binary: $ELECTRON_BIN" >&2
  echo "  请先在别处 npm install electron@43.1.0，然后设置 ELEC43_DIR" >&2
  exit 1
fi
if [ ! -f "$APP_ASAR" ]; then
  echo "[ERROR] 找不到 $APP_ASAR" >&2
  echo "  请先跑 scripts/build-linux-gui.sh 修 asar" >&2
  exit 1
fi

# 重置
if [ "$RESET" = "1" ]; then
  echo "[run] 重置 user-data-dir: $USER_DATA"
  rm -rf "$USER_DATA"
fi
mkdir -p "$USER_DATA"

# 启动参数
ARGS=(
  --no-sandbox
  --disable-gpu
  --in-process-gpu
  --disable-software-rasterizer
  --enable-logging
  --user-data-dir="$USER_DATA"
  "$APP_ASAR"
)

# Electron flags
ELECTRON_ARGS=(
  --no-sandbox
  --disable-gpu
  --in-process-gpu
  --enable-logging
)

# 环境变量
export NODE_OPTIONS="${NODE_OPTIONS:---no-deprecation}"
export ELECTRON_ENABLE_LOGGING=1
export ELECTRON_DISABLE_SECURITY_WARNINGS=1

# 启动
echo "[run] Electron: $("$ELECTRON_BIN" --version)"
echo "[run] app.asar: $APP_ASAR ($(ls -lh "$APP_ASAR" | awk '{print $5}'))"
echo "[run] user-data: $USER_DATA"
echo "[run] log: $LOG_FILE"
echo ""

# 后台启动 + 输出到 log
nohup "$ELECTRON_BIN" "${ELECTRON_ARGS[@]}" "${ARGS[@]}" > "$LOG_FILE" 2>&1 &
PID=$!
echo "[run] PID=$PID"

# 等待启动
sleep 5
if ps -p "$PID" >/dev/null 2>&1; then
  echo "[run] ✅ 启动成功"
  if [ "$VERBOSE" = "1" ]; then
    echo "---"
    tail -30 "$LOG_FILE"
  fi
else
  echo "[run] ❌ 启动失败，看 log: $LOG_FILE"
  tail -20 "$LOG_FILE"
  exit 1
fi

echo ""
echo "查看日志: tail -f $LOG_FILE"
echo "截屏会写到: $LOG_DIR/mmx-*.png (BrowserWindow 渲染后自动)"
echo "停止进程: kill $PID"
