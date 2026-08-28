#!/usr/bin/env bash
# matrix.sh — 加载 + 查 Ubuntu 版本支持矩阵
#
# Usage:
#   source tools/lib/matrix.sh
#   matrix_get <version> <field>       # e.g. matrix_get 24.04 expected_docker
#   matrix_versions [filter]            # e.g. matrix_versions 24.04 26.04 (空=全部)
#   matrix_codename <version>           # e.g. matrix_codename 24.04 -> noble
#   matrix_image <version>              # e.g. matrix_image 24.04 -> ubuntu:24.04
#   matrix_expected <version> <scope>   # scope=docker|realmachine

set -uo pipefail

_MATRIX_FILE="${_MATRIX_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/matrix.json}"
_MATRIX_CACHE=""

# 加载整个 JSON 进 _MATRIX_CACHE (用 python 解析, 比 jq/jq-less 都好)
_matrix_load() {
    if [ -n "$_MATRIX_CACHE" ]; then
        return
    fi
    if [ ! -f "$_MATRIX_FILE" ]; then
        echo "ERROR: matrix.json 不存在: $_MATRIX_FILE" >&2
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: matrix.sh 需要 python3 解析 JSON" >&2
        return 1
    fi
    _MATRIX_CACHE="$(python3 -c "
import json, sys
with open('$_MATRIX_FILE') as f:
    m = json.load(f)
# 输出 KEY=VALUE, key 用 TAB 分隔 (避免 key 里有点号被 cut 误切)
for v, info in m['versions'].items():
    for k, val in info.items():
        print(f'{v}\t{k}={val}')
" 2>&1)"
}

matrix_get() {
    local version="$1" field="$2"
    _matrix_load
    echo "$_MATRIX_CACHE" | awk -F'\t' -v v="$version" -v f="$field" '
        $1==v {
            split($2, kv, "=")
            if (kv[1] == f) { print kv[2]; exit }
        }'
}

matrix_codename() {
    matrix_get "$1" codename
}

matrix_image() {
    matrix_get "$1" image
}

matrix_expected() {
    local version="$1" scope="$2"
    matrix_get "$version" "expected_${scope}"
}

# 返回所有版本号 (filter 不空时只返回 filter 里列出的)
matrix_versions() {
    _matrix_load
    if [ $# -eq 0 ]; then
        echo "$_MATRIX_CACHE" | awk -F'\t' '{print $1}' | sort -u
    else
        printf '%s\n' "$@"
    fi
}
