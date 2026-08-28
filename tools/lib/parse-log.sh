#!/usr/bin/env bash
# parse-log.sh — 解析 electron log + state.db 状态, 给出统一 PASS/FAIL 状态
#
# Usage:
#   source tools/lib/parse-log.sh
#   parse_log_status <log-file> <scope>
#     scope=docker       # headless 容器能验: install + WindowManager login + 无 GLIBC/missing-pkg
#     scope=realmachine  # 真机/桌面能验: install + LocalRuntime ready + state.db 创建
#
# 输出 (stdout): 一个 status token
#   NO_LOG          — log 文件不存在
#   INSTALL_FAIL    — dpkg 装包失败
#   GLIBC_ERROR     — GLIBC symbol 缺失
#   MISSING_PKG     — electron-screenshots / pi-* 等 asar 内 package 找不到
#   RUNTIME_PASS    — 真机/桌面: LocalRuntimeUtility ready + state.db 创建
#   PASS            — docker: WindowManager login registered + 无 GLIBC 错
#   STARTUP_FAIL    — 其他
#
# 同时输出 detail 行 (status=... state_db=... runtime=... window=...)

set -uo pipefail

# 内部: 检查 log 里有没有特定 marker
_log_has() {
    local pattern="$1" log="$2"
    grep -qE "$pattern" "$log" 2>/dev/null
}

# 内部: 推断 detail 信息
_log_detail() {
    local log="$1"
    # state.db 状态
    if [ -f "$log" ] && grep -qE '^state_db=ok' "$log" 2>/dev/null; then
        echo "state_db=ok"
    elif [ -f "$log" ] && grep -qE '^v2_dir=ok' "$log" 2>/dev/null; then
        echo "state_db=ok"
    elif [ -f "$log" ] && grep -qE '^state_db=missing' "$log" 2>/dev/null; then
        echo "state_db=missing"
    else
        echo "state_db=unknown"
    fi
    # runtime 状态
    if _log_has 'LocalRuntimeUtility.*runtime (started|ready)' "$log"; then
        echo "runtime=ready"
    elif _log_has 'LocalRuntimeUtility' "$log"; then
        echo "runtime=init"
    else
        echo "runtime=na"
    fi
    # window 状态
    if _log_has 'WindowManager.*Registered window.*type=login' "$log"; then
        echo "window=login"
    elif _log_has 'WindowManager.*Registered window' "$log"; then
        echo "window=other"
    else
        echo "window=none"
    fi
}

parse_log_status() {
    local log="$1" scope="${2:-docker}"
    
    if [ ! -f "$log" ]; then
        echo "NO_LOG"
        return
    fi
    
    # 通用: 安装失败
    if ! _log_has 'install ok installed' "$log"; then
        echo "INSTALL_FAIL"
        return
    fi
    
    # 通用: GLIBC 错误
    if _log_has 'GLIBC_2\.38.*not found|version `GLIBC_2\.3[5-9]' "$log"; then
        echo "GLIBC_ERROR"
        return
    fi
    
    # 通用: missing package
    if _log_has 'Cannot find package.*@earendil' "$log"; then
        echo "MISSING_PKG"
        return
    fi
    
    # 按 scope 分支
    case "$scope" in
        docker)
            # headless 容器: 装上 + 启动到 login = 真 PASS
            if _log_has 'state_db=ok' "$log"; then
                echo "RUNTIME_PASS"  # 意外之喜 (其实 headless 跑不到)
            elif _log_has 'v2_dir=ok' "$log"; then
                echo "RUNTIME_PASS"
            elif _log_has 'LocalRuntimeUtility.*runtime (started|ready)' "$log"; then
                echo "RUNTIME_PASS"
            elif _log_has 'WindowManager.*Registered window.*type=login' "$log"; then
                echo "PASS"
            else
                echo "STARTUP_FAIL"
            fi
            ;;
        realmachine)
            # 真机/桌面: 必须 state.db 创建才算 RUNTIME_PASS
            # WindowManager login registered 是过渡状态 (等用户登录)
            if _log_has 'state_db=ok' "$log"; then
                echo "RUNTIME_PASS"
            elif _log_has 'v2_dir=ok' "$log"; then
                echo "RUNTIME_PASS"
            elif _log_has 'LocalRuntimeUtility.*runtime (started|ready)' "$log"; then
                # 起来了但 state.db 还在写 (少见, 给 partial)
                echo "RUNTIME_PASS"
            elif _log_has 'WindowManager.*Registered window.*type=login' "$log"; then
                echo "LOGIN_READY"
            else
                echo "STARTUP_FAIL"
            fi
            ;;
        *)
            echo "STARTUP_FAIL"
            ;;
    esac
}
