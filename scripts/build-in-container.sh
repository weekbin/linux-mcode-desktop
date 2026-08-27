#!/usr/bin/env bash
# build-in-container.sh — 在 macOS 上跑全 Linux pipeline
#
# 用途: macOS 上没有 linux-x64 toolchain, 但 Docker Desktop 在跑。
#       这脚本拉 ubuntu:24.04 容器 (--platform linux/amd64 走 qemu binfmt),
#       装齐 build 依赖, 跑 build-linux-gui.sh + build-deb.sh
#
# 用法:
#   ./scripts/build-in-container.sh              # 完整跑 (Stage A+B+C, 产物在 ./dist/)
#   ./scripts/build-in-container.sh --no-clean   # 保留容器 (debug)
#   ./scripts/build-in-container.sh --skip-deps  # 跳过 apt install (二次跑加速)
#
# 前置:
#   - Docker Desktop 跑着
#   - 已 brew install p7zip dpkg
#   - inputs/MiniMax-Code-Setup-3.0.67-inside.44.exe 存在
#
# 输出:
#   - dist/minimax-code_3.0.67-inside.44_amd64.deb
#
# 性能 (Apple Silicon Mac, qemu amd64 模拟):
#   - apt install ~80MB:        5-10 分钟
#   - node + electron 下载:     3-5 分钟
#   - better-sqlite3 + node-pty rebuild:  10-15 分钟
#   - dpkg-deb --build (1.3GB):  10-15 分钟
#   - 总计:                     30-50 分钟

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# 参数
KEEP_CONTAINER=""
SKIP_DEPS=""
UBUNTU_TAG="24.04"
CONTAINER_NAME="mmx-build-$$"

for arg in "$@"; do
    case "$arg" in
        --no-clean)  KEEP_CONTAINER="--name $CONTAINER_NAME";;
        --skip-deps) SKIP_DEPS=1;;
        2[0-9]\.[0-9][0-9]) UBUNTU_TAG="$arg";;
        *) echo "unknown arg: $arg" >&2; exit 1;;
    esac
done

# --- 1) Mac 端 prep: 提取 icon.png ---
if [ ! -f "unpacked/app-64/resources/resources/icon.png" ]; then
    echo "[prep] 提取 icon.png 从 icon.ico (内部 PNG) ..."
    python3 <<'PYEOF'
import struct
ico = "unpacked/app-64/resources/resources/icon.ico"
with open(ico, "rb") as f: data = f.read()
_, _, count = struct.unpack_from("<HHH", data, 0)
assert count == 1, f"unexpected icon count {count}"
_, _, _, _, _, _, sz, off = struct.unpack_from("<BBBBHHII", data, 6)
assert data[off:off+8] == b'\x89PNG\r\n\x1a\n', "icon.ico doesn't start with PNG"
with open("unpacked/app-64/resources/resources/icon.png", "wb") as f: f.write(data[off:off+sz])
print(f"  [ok] icon.png = {sz} bytes (256x256 RGBA)")
PYEOF
fi

# --- 2) Mac 端 prep: 创建 README-LINUX.md (build-deb.sh:210 期待) ---
if [ ! -f "README-LINUX.md" ]; then
    echo "[prep] 创建 README-LINUX.md ..."
    cat > README-LINUX.md <<'EOF'
# MiniMax Code (Linux)

Linux GUI client built from the Windows NSIS installer via `@mmx-agent/electron v3.0.67-inside.44`.

## Install

```bash
sudo dpkg -i minimax-code_3.0.67-inside.44_amd64.deb
sudo apt-get install -f -y   # if unmet deps
```

## Launch

```bash
minimax-code
# or
/opt/MiniMax\ Code/run.sh
```

## Uninstall

```bash
sudo dpkg --purge minimax-code
```

## Notes

- Built on Ubuntu 24.04 (GLIBC 2.39). Older distros (22.04 jammy, 20.04 focal)
  need the `libmmmx-shim.so` preloaded (already bundled at `/opt/mmx-shared/`).
- On headless servers: `xvfb-run -a minimax-code` or set `DISPLAY=:99` with Xvfb.
EOF
fi

# --- 3) 写容器内命令到临时文件 (避免双层 bash 引号) ---
CONTAINER_CMD_FILE="$(mktemp -t mmx-container-cmd.XXXXXX.sh)"
cat > "$CONTAINER_CMD_FILE" <<'CONTAINER_EOF'
#!/usr/bin/env bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "▶ apt update + 最小化 build tools install (Rosetta 下慢, 只装必要)"
apt-get update -qq 2>&1 | tail -2
apt-get install -y --no-install-recommends \
    p7zip-full dpkg-dev gcc g++ make python3 ca-certificates curl 2>&1 | tail -2

echo "▶ node 22 (Ubuntu 24.04 ships 20.x, too old)"
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 22 ]; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
    apt-get install -y -qq nodejs
fi
node -v
npm -v

echo "▶ ELEC43_DIR = Electron 43.1.0 (linux-x64)"
mkdir -p /tmp/elec43
(cd /tmp/elec43 && npm init -y >/dev/null 2>&1 && npm install electron@43.1.0 --no-save 2>&1 | tail -3)

echo "▶ build libmmmx shim (Mac clang 不认 .symver, 必须 Linux gcc)"
mkdir -p /work/dist-lib
gcc -shared -fPIC -nostdlib -o /work/dist-lib/libfmod_shim.so \
    /work/src/libmmmx-shim.c -Wl,--version-script=/work/src/libmmmx-shim.map
nm -D /work/dist-lib/libfmod_shim.so | grep fmod

echo "▶ Stage A + B: build-linux-gui.sh (asar extract + native rebuild)"
export ELEC43_DIR=/tmp/elec43/node_modules/electron
cd /work
./scripts/build-linux-gui.sh

echo "▶ Stage C: build-deb.sh (打 .deb)"
./scripts/build-deb.sh

echo
echo "============================================"
echo "✅  打包完成"
echo "============================================"
ls -lh /work/dist/
CONTAINER_EOF
chmod +x "$CONTAINER_CMD_FILE"
echo "[prep] container command file: $CONTAINER_CMD_FILE"

# --- 4) docker run ---
# === mmx-patch: --platform linux/amd64 ===
# 在 Apple Silicon Mac 上, 默认 ubuntu:24.04 镜像会跑 arm64 (aarch64),
# 但 build-deb.sh 输出目标是 amd64, apt 包 / electron binary / native binding 全得是 x86_64.
# 用 --platform linux/amd64 触发 qemu binfmt 模拟 (慢 2-3x 但能跑出正确的 .deb)
# 在 x86_64 host 上, --platform 会被忽略, 性能不变
DOCKER_OPTS=(
    --rm $KEEP_CONTAINER
    --platform linux/amd64
    -v "$PROJECT_ROOT:/work"
    -v "$CONTAINER_CMD_FILE:/tmp/container-cmd.sh"
    -w /work
    -e "DEBIAN_FRONTEND=noninteractive"
    -i
    "ubuntu:$UBUNTU_TAG"
)

echo "[run] docker run ubuntu:$UBUNTU_TAG (--platform linux/amd64) ..."
echo "[run] 容器内 5 步: apt install (5-10min) → node + electron (3-5min) → shim build (5s) → Stage A+B rebuild (10-15min) → Stage C deb (10-15min)"
echo "[run] 总计约 30-50 分钟 (qemu 模拟 amd64 慢)"
echo

# -i 保持 stdin 打开, 不用 -t 因为 CI/agent 没有 TTY
docker run -i "${DOCKER_OPTS[@]}" bash /tmp/container-cmd.sh

echo
echo "✅ 容器内 build 完成"
ls -lh "$PROJECT_ROOT/dist/" 2>/dev/null || echo "(no dist/ — see container log above)"

# 清理临时文件
rm -f "$CONTAINER_CMD_FILE"
