#!/usr/bin/env bash
# test-real-machine.sh — 真机/桌面环境 runtime 验证 (FINAL RELEASE 路径)
#
# 验证范围 (要 GUI/有 user, 不能在 headless 容器跑):
#   ✅ deb 装包
#   ✅ electron 启动到 WindowManager login
#   ✅ OAuth 登录后 LocalRuntimeUtility 启动
#   ✅ state.db 创建 (v2/sqlite/runtime-state.sqlite)
#   ✅ V2 migration 完成
#
# 这个脚本是给 release 之前在真机上手动跑一次用的, 不能在 CI 跑
# 因为要真实 GUI + 人工 OAuth 登录.
#
# Usage:
#   tools/test-real-machine.sh                   # 完整测
#   tools/test-real-machine.sh --until-login     # 只到 login 窗口 (不需要 OAuth 账号)
#   tools/test-real-machine.sh --timeout 600     # 自定义超时 (默认 600s = 10min, 给 OAuth 留时间)
#
# 需要:
#   - 在目标 Ubuntu 机器上跑 (不能 docker)
#   - 已 build 的 dist/minimax-code_3.0.67-inside.44_amd64.deb
#   - GUI (有 DISPLAY 或 wayland)
#   - 网络 (OAuth 要回调)
#   - 真实账号 (要登录)
#
# 版本支持矩阵见 tools/lib/matrix.json

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/matrix.sh
source "$SCRIPT_DIR/lib/matrix.sh"
# shellcheck source=lib/parse-log.sh
source "$SCRIPT_DIR/lib/parse-log.sh"

DEB_PATH="${DEB_PATH:-$PROJECT_ROOT/dist/minimax-code_3.0.67-inside.44_amd64.deb}"
LOG_DIR="$PROJECT_ROOT/.test-logs"
LOG_FILE="$LOG_DIR/realmachine-$(date +%Y%m%d-%H%M%S).log"
SCOPE="realmachine"
UNTIL_LOGIN=0
TIMEOUT=600
SKIP_DEB_INSTALL=0

# parse args
for arg in "$@"; do
    case "$arg" in
        --until-login) UNTIL_LOGIN=1 ;;
        --timeout)     TIMEOUT="$2"; shift ;;
        --timeout=*)   TIMEOUT="${arg#*=}" ;;
        --skip-install) SKIP_DEB_INSTALL=1 ;;
        -h|--help)
            sed -n '3,24p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *) echo "未知参数: $arg"; exit 2 ;;
    esac
done

# 准备
mkdir -p "$LOG_DIR"

# 检测当前 Ubuntu 版本
if [ -f /etc/os-release ]; then
    . /etc/os-release
    UBUNTU_VERSION="${VERSION_ID:-unknown}"
    UBUNTU_CODENAME_LOCAL="${UBUNTU_CODENAME:-unknown}"
else
    echo "ERROR: 无法检测 Ubuntu 版本 (没有 /etc/os-release)"
    exit 1
fi
echo "=== 当前系统: Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME_LOCAL) ==="

# 查 matrix
expected="$(matrix_expected "$UBUNTU_VERSION" "$SCOPE" 2>/dev/null || echo "UNKNOWN")"
if [ "$expected" = "UNKNOWN" ]; then
    echo "WARN: matrix.json 没记录 $UBUNTU_VERSION, 按 FAIL 处理"
    expected="FAIL"
fi
echo "    matrix 预期 (scope=$SCOPE): $expected"
echo "    reason: $(matrix_get "$UBUNTU_VERSION" reason)"
echo ""

# 装 deb
if [ "$SKIP_DEB_INSTALL" = "0" ]; then
    if [ ! -f "$DEB_PATH" ]; then
        echo "ERROR: deb 不存在: $DEB_PATH"
        exit 1
    fi
    echo "=== 装 deb ==="
    sudo dpkg -i "$DEB_PATH" 2>&1 | tail -8 | tee -a "$LOG_FILE"
    # preinst 应该已经处理过依赖, 但保险起见再跑一次
    sudo apt-get install -f -y 2>&1 | tail -3 | tee -a "$LOG_FILE"
fi

# 检查装包状态
if ! dpkg -s minimax-code 2>/dev/null | grep -qE 'install ok installed'; then
    echo "✗ INSTALL_FAIL"
    echo "---"
    echo "详细 log: $LOG_FILE"
    exit 1
fi
echo "install_ok=1" | tee -a "$LOG_FILE"

# 启动 electron
echo ""
echo "=== 启动 electron (timeout=${TIMEOUT}s) ==="
if [ "$UNTIL_LOGIN" = "1" ]; then
    echo "(--until-login: 看到 login 窗口就停, 不需要登录)"
fi

# 用 Xvfb 兜底 (没真 X 时)
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    if command -v Xvfb >/dev/null 2>&1; then
        echo "(无 DISPLAY, 用 Xvfb :99)"
        Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
        XVFB_PID=$!
        sleep 2
        export DISPLAY=:99
        trap "kill $XVFB_PID 2>/dev/null" EXIT
    else
        echo "ERROR: 没有 DISPLAY/WAYLAND_DISPLAY, 也没 Xvfb. 装 Xvfb 或在桌面环境跑."
        exit 1
    fi
fi

# 启动 + 看 log
timeout "$TIMEOUT" /opt/MiniMax\ Code/run.sh > "$LOG_FILE" 2>&1 &
MMX_PID=$!

# 监控 loop, 检查关键 marker
deadline=$(( $(date +%s) + TIMEOUT ))
last_state=""
while [ $(date +%s) -lt $deadline ]; do
    sleep 5
    # 看实时 log
    if [ -f "$LOG_FILE" ]; then
        # state.db 创建 → RUNTIME_PASS
        if [ -f "/root/.config/MiniMax-Code/v2/sqlite/runtime-state.sqlite" ] || \
           [ -f "$HOME/.config/MiniMax-Code/v2/sqlite/runtime-state.sqlite" ]; then
            echo ""
            echo "✓ state.db 已创建" | tee -a "$LOG_FILE"
            state_db=ok
            break
        fi
        # LocalRuntimeUtility ready
        if grep -qE 'LocalRuntimeUtility.*runtime (started|ready)' "$LOG_FILE" 2>/dev/null; then
            echo ""
            echo "✓ LocalRuntimeUtility runtime ready" | tee -a "$LOG_FILE"
            state_db="almost (waiting for state.db)"
            # 给 state.db 几秒写入
            sleep 10
            if [ -f "/root/.config/MiniMax-Code/v2/sqlite/runtime-state.sqlite" ] || \
               [ -f "$HOME/.config/MiniMax-Code/v2/sqlite/runtime-state.sqlite" ]; then
                state_db=ok
            fi
            break
        fi
        # login 窗口 (--until-login 模式到这就停)
        if [ "$UNTIL_LOGIN" = "1" ] && grep -qE 'WindowManager.*Registered window.*type=login' "$LOG_FILE" 2>/dev/null; then
            echo ""
            echo "✓ WindowManager login registered (--until-login 模式)" | tee -a "$LOG_FILE"
            break
        fi
        # GLIBC error 早停
        if grep -qE 'GLIBC_2\.38.*not found|version `GLIBC_2\.3[5-9]' "$LOG_FILE" 2>/dev/null; then
            echo ""
            echo "✗ GLIBC error detected" | tee -a "$LOG_FILE"
            break
        fi
    fi
done

# 评估
# 把 monitor 看到的 state_db 状态写到 log (parse_log_status 会读)
if [ "${state_db:-}" = "ok" ]; then
    echo "state_db=ok" >> "$LOG_FILE"
elif [ -n "${state_db:-}" ]; then
    echo "state_db=$state_db" >> "$LOG_FILE"
else
    echo "state_db=missing (timeout ${TIMEOUT}s 未创建)" >> "$LOG_FILE"
fi

# 杀进程
kill $MMX_PID 2>/dev/null
wait $MMX_PID 2>/dev/null

# 看结果
echo ""
echo "=== 评估 ==="
actual="$(parse_log_status "$LOG_FILE" "$SCOPE")"
echo "expected: $expected"
echo "actual:   $actual"
echo ""
echo "详细 log: $LOG_FILE"
echo "状态 detail: $(_log_detail "$LOG_FILE" | tr '\n' ' ')"
echo ""
if [ "$actual" = "$expected" ]; then
    echo "✓ $actual (符合预期)"
    exit 0
else
    echo "✗ expected=$expected, got=$actual"
    exit 1
fi
