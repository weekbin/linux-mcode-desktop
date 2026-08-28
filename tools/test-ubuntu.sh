#!/usr/bin/env bash
# test-ubuntu.sh — 跨 Ubuntu 版本冒烟测试
#
# 对每个 Ubuntu LTS / 25.10 启动 docker 容器:
#   1. 装所有 electron runtime 依赖
#   2. 装本仓库 build 出来的 .deb
#   3. 跑 electron 30 秒, 检查关键 log marker
#
# Usage:
#   tools/test-ubuntu.sh                       # 测所有支持版本
#   tools/test-ubuntu.sh 24.04 26.04          # 只测指定版本
#   tools/test-ubuntu.sh --no-cleanup 24.04   # 测完后保留容器 (debug)
#
# 需要:
#   - docker
#   - 已 build 出来的 dist/minimax-code_3.0.67-inside.44_amd64.deb
#   - /tmp/.X11-unix 共享 (用 Xvfb 不需要真实 X server)
#
# 每个版本预期 runtime:
#   noble  (24.04): ✅ 完全支持
#   resolute (26.04): ✅ 完全支持 (GLIBC 更新, 一些新 package 名)
#   plucky  (25.04): ✅ 完整支持 (类似 24.04)
#   questing (25.10): ✅ 完整支持 (类似 26.04)
#   jammy   (22.04): ⚠️ 安装 OK, runtime 需 shim 链接验证 (per AGENTS.md §6 P0)
#   focal   (20.04): ❌ GLIBC 2.31 太老, electron 43 V8 跑不动

set -uo pipefail

DEB_PATH="${DEB_PATH:-$(dirname "$(realpath "$0")")/../dist/minimax-code_3.0.67-inside.44_amd64.deb}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$PROJECT_ROOT/.test-logs"
CLEANUP=1

# parse args
SELECTED=()
for arg in "$@"; do
    case "$arg" in
        --no-cleanup) CLEANUP=0 ;;
        -h|--help)
            sed -n '3,28p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *) SELECTED+=("$arg") ;;
    esac
done

# 支持的版本映射
declare -A UBUNTU_IMAGES=(
    [20.04]="ubuntu:20.04"
    [22.04]="ubuntu:22.04"
    [24.04]="ubuntu:24.04"
    [25.04]="ubuntu:25.04"
    [25.10]="ubuntu:25.10"
    [26.04]="ubuntu:26.04"
)
# 每个版本预期 runtime:
#   noble  (24.04): ✅ 完全支持
#   resolute (26.04): ✅ 完全支持 (GLIBC 更新, 一些新 package 名)
#   plucky  (25.04): ✅ 完整支持 (类似 24.04)
#   questing (25.10): ✅ 完整支持 (类似 26.04)
#   jammy   (22.04): ⚠️ 安装 OK, runtime 需 shim 链接验证 (per AGENTS.md §6 P0)
#   focal   (20.04): ❌ GLIBC 2.31 太老, electron 43 V8 跑不动
#
# 注: headless 容器里 LocalRuntimeUtility 不会启动 (要 OAuth 登录才起),
#     所以 state.db / v2_dir 在容器里看不到. 真实部署时 (有 user 登录)
#     这些都会创建. 测 LocalRuntime 要在真机 / 桌面环境跑.
declare -A UBUNTU_CODENAME=(
    [20.04]="focal"
    [22.04]="jammy"
    [24.04]="noble"
    [25.04]="plucky"
    [25.10]="questing"
    [26.04]="resolute"
)
# 预期 marker (按版本支持状态)
#   PASS    = deb 装上 + electron 启动到 login 窗口 + 无 GLIBC/missing-pkg
#             (headless 容器里 LocalRuntime 要等 OAuth, 测不到)
#   PARTIAL = 装上启动, 但有 GLIBC shim 链路问题 (better_sqlite3 需 libmmmx)
#   FAIL    = 装不上 / 启动不到 WindowManager / GLIBC 太老
declare -A EXPECTED=(
    [20.04]="FAIL"     # GLIBC 2.31 太老, V8 symbols 不全
    [22.04]="PARTIAL"  # 装上启动, 但 better_sqlite3 fmod@GLIBC_2.38 链接要 libmmmx 验证
    [24.04]="PASS"     # GLIBC 2.39, 完整支持
    [25.04]="PASS"
    [25.10]="PASS"
    [26.04]="PASS"
)

# 选择要测的版本
if [ ${#SELECTED[@]} -eq 0 ]; then
    SELECTED=(20.04 22.04 24.04 25.04 25.10 26.04)
fi

# 准备
mkdir -p "$LOG_DIR"
if [ ! -f "$DEB_PATH" ]; then
    echo "ERROR: deb 不存在: $DEB_PATH"
    echo "  先跑 npm run build:deb"
    exit 1
fi

# 镜像预拉 (省时间)
echo "=== 预拉镜像 ==="
for v in "${SELECTED[@]}"; do
    image="${UBUNTU_IMAGES[$v]}"
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
    local image="${UBUNTU_IMAGES[$version]}"
    local codename="${UBUNTU_CODENAME[$version]}"
    local container="mmxtest-${codename}-$$"
    local log="$LOG_DIR/${codename}.log"
    local expected="${EXPECTED[$version]}"
    
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
# 按版本补 alternates
apt-get install -y --no-install-recommends libgtk-3-0t64 2>/dev/null
apt-get install -y --no-install-recommends libgtk-3-0 2>/dev/null
apt-get install -y --no-install-recommends libasound2t64 2>/dev/null
apt-get install -y --no-install-recommends libasound2 2>/dev/null
apt-get install -y --no-install-recommends libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libxcb-dri3-0 2>&1 | tail -2
# 2) 装 deb
echo '--- 装 deb ---'
dpkg -i /tmp/minimax.deb 2>&1 | tail -8
# 输出完整的 dpkg-s Status 给外部 grep
dpkg -s minimax-code 2>/dev/null | grep -E '^(Package|Status|Version):' | head -3
echo \"install_ok=1\"
# 也输出完整 Status 行, 让外部 grep 容易判断
dpkg -s minimax-code 2>/dev/null | grep -E '^(Package|Status|Version):' | head -3
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
STATE_DB="/root/.config/MiniMax-Code/v2/sqlite/runtime-state.sqlite"
V2_DIR="/root/.config/MiniMax-Code/v2"
WINDOW_LOG="WindowManager.*Registered window"
if [ -f "\$STATE_DB" ]; then
    echo 'state_db=ok'
elif [ -d "\$V2_DIR" ]; then
    echo 'v2_dir=ok (LocalRuntime 已 init)'
elif grep -qE \"\$WINDOW_LOG\" /tmp/mmx.log 2>/dev/null; then
    echo 'state_db=missing (需要 OAuth 登录才能起 LocalRuntime)'
fi
" 2>&1 | tee "$log"
    
    # 5) 评估结果
    # PASS 判定: install ok + electron 启动到 login 窗口 + 无 GLIBC/missing-pkg 错
    # (state.db 在 headless 容器里跑不到, 要 OAuth 登录, 那不是冒烟测试该做的)
    if [ ! -f "$log" ]; then
        actual="NO_LOG"
    elif ! grep -qE 'install ok installed' "$log" 2>/dev/null; then
        actual="INSTALL_FAIL"
    elif grep -qE 'GLIBC_2.38.*not found|version `GLIBC_2\.3[5-9]' "$log" 2>/dev/null; then
        actual="GLIBC_ERROR"
    elif grep -qE 'Cannot find package.*@earendil' "$log" 2>/dev/null; then
        actual="MISSING_PKG"
    elif grep -qE 'state_db=ok' "$log" 2>/dev/null; then
        actual="RUNTIME_PASS"
    elif grep -qE 'v2_dir=ok' "$log" 2>/dev/null; then
        actual="RUNTIME_PASS"
    elif grep -qE 'LocalRuntimeUtility.*runtime (started|ready)' "$log" 2>/dev/null; then
        actual="RUNTIME_PASS"
    elif grep -qE 'WindowManager.*Registered window.*type=login' "$log" 2>/dev/null; then
        # headless 容器最高可达状态: login 窗口已 register, 等用户登录
        # 真实部署时 (有 user 登录) LocalRuntimeUtility 才会起来, 容器里测不到
        actual="PASS"
    else
        actual="STARTUP_FAIL"
    fi
    
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
echo " 总结: $passed/$total 通过预期"
echo " 详细 log 在: $LOG_DIR/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[ "$passed" -eq "$total" ]
