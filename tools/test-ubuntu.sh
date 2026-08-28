#!/usr/bin/env bash
# test-ubuntu.sh — 跨 Ubuntu 版本冒烟测试 (DOCKER / HEADLESS 路径)
#
# 验证范围 (受 headless 限制):
#   ✅ deb 装包
#   ✅ electron 启动到 WindowManager login 窗口
#   ✅ 无 GLIBC / missing-pkg 错
#   ❌ 测不到 LocalRuntimeUtility (要 OAuth 登录才起)
#   ❌ 测不到 state.db / v2_dir (同上)
#
# 完整 runtime 验证见 tools/test-real-machine.sh
#
# Usage:
#   tools/test-ubuntu.sh                       # 测所有支持版本
#   tools/test-ubuntu.sh 24.04 26.04          # 只测指定版本
#   tools/test-ubuntu.sh --no-cleanup 24.04   # 测完保留容器 (debug)
#
# 需要:
#   - docker
#   - 已 build 出来的 dist/minimax-code_3.0.67-inside.44_amd64.deb
#
# 版本支持矩阵见 tools/lib/matrix.json (单源数据, AGENTS/README 都引用它)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/matrix.sh
source "$SCRIPT_DIR/lib/matrix.sh"
# shellcheck source=lib/parse-log.sh
source "$SCRIPT_DIR/lib/parse-log.sh"

DEB_PATH="${DEB_PATH:-$PROJECT_ROOT/dist/minimax-code_3.0.67-inside.44_amd64.deb}"
LOG_DIR="$PROJECT_ROOT/.test-logs"
CLEANUP=1
SCOPE="docker"

# parse args
SELECTED=()
for arg in "$@"; do
    case "$arg" in
        --no-cleanup) CLEANUP=0 ;;
        -h|--help)
            sed -n '3,22p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *) SELECTED+=("$arg") ;;
    esac
done

# 准备
mkdir -p "$LOG_DIR"
if [ ! -f "$DEB_PATH" ]; then
    echo "ERROR: deb 不存在: $DEB_PATH"
    echo "  先跑 npm run build:deb"
    exit 1
fi

# 选择要测的版本
if [ ${#SELECTED[@]} -eq 0 ]; then
    mapfile -t SELECTED < <(matrix_versions)
fi

# 镜像预拉
echo "=== 预拉镜像 ==="
for v in "${SELECTED[@]}"; do
    image="$(matrix_image "$v")"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        echo "拉 $image ..."
        docker pull "$image" 2>&1 | tail -1
    else
        echo "  $image (已缓存)"
    fi
done

# 测试函数
test_version() {
    local version="$1"
    local image codename container log expected
    image="$(matrix_image "$version")"
    codename="$(matrix_codename "$version")"
    container="mmxtest-${codename}-$$"
    log="$LOG_DIR/${codename}.log"
    expected="$(matrix_expected "$version" docker)"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  测试 Ubuntu $version ($codename) → 预期: $expected"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 装 deb + 跑 electron (apt-get 可能很慢, 600s timeout)
    timeout 600 docker run --rm --name "$container" \
        -v "$DEB_PATH":/tmp/minimax.deb:ro \
        "$image" bash -c "
set +e
export DEBIAN_FRONTEND=noninteractive
# 1) 装运行时依赖 (按版本差异, 部分包 26.04+ 可能没有)
apt-get update -qq 2>&1 | tail -1
apt-get install -y --no-install-recommends \
    libnss3 libnspr4 libxkbcommon0 libgbm1 libnotify4 libsecret-1-0 libxss1 libxtst6 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxshmfence1 \
    libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 libcups2 libdbus-1-3 libexpat1 \
    libglib2.0-0 libxext6 xvfb dbus sudo ca-certificates fonts-liberation 2>&1 | tail -3
# 按版本补 alternates (24.04+ 用 t64, 老的没有)
apt-get install -y --no-install-recommends libgtk-3-0t64 2>/dev/null
apt-get install -y --no-install-recommends libgtk-3-0 2>/dev/null
apt-get install -y --no-install-recommends libasound2t64 2>/dev/null
apt-get install -y --no-install-recommends libasound2 2>/dev/null
apt-get install -y --no-install-recommends libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libxcb-dri3-0 2>&1 | tail -2
# 2) 装 deb
echo '--- 装 deb ---'
dpkg -i /tmp/minimax.deb 2>&1 | tail -8
dpkg -s minimax-code 2>/dev/null | grep -E '^(Package|Status|Version):' | head -3
echo \"install_ok=1\"
# 3) 跑 electron (Xvfb, 180s 足够 init 到 login 窗口)
echo '--- 启动 electron (180s timeout) ---'
mkdir -p /root/.config/MiniMax-Code
Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
XVFB_PID=\$!
sleep 2
export DISPLAY=:99
timeout 180 /opt/MiniMax\ Code/run.sh > /tmp/mmx.log 2>&1
RC=\$?
kill \$XVFB_PID 2>/dev/null
echo \"exit=\$RC\"
echo '--- 关键 log ---'
grep -E 'LocalRuntimeUtility|GLIBC|fmod|Cannot find package|login|WindowManager|MiniMax Code' /tmp/mmx.log | head -10
echo '--- runtime 初始化检查 ---'
# 真实环境 LocalRuntimeUtility V2 migration 创建 runtime-state.sqlite
# 但 headless 容器 OAuth 登录跑不了, 永远到不了 V2 migration
# 所以 headless 测只验: 启动到 login 窗口 + 无 GLIBC/missing-pkg 错
STATE_DB=\"/root/.config/MiniMax-Code/v2/sqlite/runtime-state.sqlite\"
V2_DIR=\"/root/.config/MiniMax-Code/v2\"
WINDOW_LOG=\"WindowManager.*Registered window\"
if [ -f \"\$STATE_DB\" ]; then
    echo 'state_db=ok'
elif [ -d \"\$V2_DIR\" ]; then
    echo 'v2_dir=ok (LocalRuntime 已 init)'
elif grep -qE \"\$WINDOW_LOG\" /tmp/mmx.log 2>/dev/null; then
    echo 'state_db=missing (需要 OAuth 登录才能起 LocalRuntime)'
fi
" 2>&1 | tee "$log"
    
    # 4) 评估
    local actual
    actual="$(parse_log_status "$log" "$SCOPE")"
    
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $codename: $actual (符合预期)"
        return 0
    else
        echo "  ✗ $codename: expected=$expected, got=$actual"
        return 1
    fi
}

# 主循环
total=0
passed=0
for v in "${SELECTED[@]}"; do
    total=$((total+1))
    if test_version "$v"; then
        passed=$((passed+1))
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 总结: $passed/$total 通过预期 (scope=$SCOPE)"
echo " 详细 log 在: $LOG_DIR/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[ "$passed" -eq "$total" ]
