#!/usr/bin/env bash
# build-all.sh — 一键打 .deb + .tar.gz
# 等价于: build-linux-gui.sh + build-deb.sh + build-targz.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "===================================="
echo " MiniMax Code Linux Build Pipeline"
echo "===================================="
echo ""

# Step 1: 修 asar (装 native bindings + JS patches)
echo "=== Step 1/3: 修 asar (装 native bindings + JS patches) ==="
bash "$SCRIPT_DIR/build-linux-gui.sh"
echo ""

# Step 2: 打 deb
echo "=== Step 2/3: 打 .deb ==="
bash "$SCRIPT_DIR/build-deb.sh" 2>&1 | tail -8
echo ""

# Step 3: 打 tar.gz
echo "=== Step 3/3: 打 .tar.gz ==="
bash "$SCRIPT_DIR/build-targz.sh" 2>&1 | tail -8
echo ""

echo "===================================="
echo " ✅ All builds complete"
echo "===================================="
ls -lh "$PROJECT_ROOT/dist/" 2>/dev/null
