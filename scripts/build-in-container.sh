#!/usr/bin/env bash
# build-in-container.sh — 在 macOS 上跑全 Linux pipeline
#
# 用途: macOS 上没有 linux-x64 toolchain, 但 Docker Desktop 在跑。
#       这脚本拉 ubuntu:24.04 容器 (--platform linux/amd64 走 qemu binfmt),
#       装齐 build 依赖, 跑 build-linux-gui.sh + build-deb.sh
#
# 用法:
#   ./scripts/build-in-container.sh                     # 完整跑 (Stage A+B+C, 产物在 ./dist/)
#   ./scripts/build-in-container.sh --no-clean          # 保留容器 (debug)
#   ./scripts/build-in-container.sh --skip-deps         # 跳过 apt install (用 mmx-build-env 镜像)
#   ./scripts/build-in-container.sh --from-image=X      # 从指定镜像起 (e.g. mmx-build-env:latest)
#   ./scripts/build-in-container.sh --save-image=NAME   # 跑完后 commit 到镜像
#   ./scripts/build-in-container.sh --keep-stage=NAME   # commit 后保留容器 (debug)
#
# 前置:
#   - Docker Desktop 跑着
#   - 已 brew install p7zip dpkg
#   - inputs/MiniMax-Code-Setup-3.0.67-inside.44.exe 存在
#
# 性能 (Apple Silicon Mac, qemu amd64 模拟):
#   - apt install ~80MB:        5-10 分钟 (有代理更快)
#   - node + electron 下载:     3-5 分钟
#   - better-sqlite3 + node-pty rebuild:  10-15 分钟
#   - dpkg-deb --build (1.3GB):  10-15 分钟
#   - 总计:                     30-50 分钟
#
# === mmx-patch: 镜像复用 ===
# 第一次跑会 apt install + node + electron, 慢
# 跑完用 --save-image=mmx-build-env 保存镜像
# 下次跑用 --from-image=mmx-build-env --skip-deps 直接进入 rebuild 阶段, 省 10+ 分钟
# 关键点: 不要每次都重 apt, 把 apt 缓存 + node + electron 全在镜像里

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# 参数
KEEP_CONTAINER=""
SKIP_DEPS=""
UBUNTU_TAG="24.04"
CONTAINER_NAME="mmx-build-$$"
SAVE_IMAGE=""
FROM_IMAGE=""

for arg in "$@"; do
    case "$arg" in
        --no-clean)        KEEP_CONTAINER=1;;
        --skip-deps)       SKIP_DEPS=1;;
        --save-image=*)    SAVE_IMAGE="${arg#*=}";;   # e.g. mmx-build-env
        --from-image=*)    FROM_IMAGE="${arg#*=}";;   # e.g. mmx-build-env:latest
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
if [ -n "$SKIP_DEPS" ]; then
    echo "[prep] 跳过 apt install (假设 FROM_IMAGE 已装好依赖)"
    cat > "$CONTAINER_CMD_FILE" <<'CONTAINER_EOF'
#!/usr/bin/env bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "▶ 复用 FROM_IMAGE 已有 build 工具, 跳过 apt install"
# 验证依赖存在
for cmd in node npm gcc g++ make python3 wget file p7zip dpkg-deb; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "[ERROR] 缺命令: $cmd — 镜像不完整, 别用 --skip-deps"
        exit 1
    fi
done

echo "▶ ELEC43_DIR = Electron 43.1.0 (linux-x64)"
mkdir -p /tmp/elec43
if [ ! -d /tmp/elec43/node_modules/electron ]; then
    (cd /tmp/elec43 && npm init -y >/dev/null 2>&1 && npm install electron@43.1.0 --no-save 2>&1 | tail -3)
fi

echo "▶ build libmmmx shim (Mac clang 不认 .symver, 必须 Linux gcc)"
mkdir -p /work/lib
if [ ! -f /work/lib/libfmod_shim.so ]; then
    gcc -shared -fPIC -nostdlib -o /work/lib/libfmod_shim.so \
        /work/src/libmmmx-shim.c -Wl,--version-script=/work/src/libmmmx-shim.map
fi
nm -D /work/lib/libfmod_shim.so | grep fmod

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
else
    cat > "$CONTAINER_CMD_FILE" <<'CONTAINER_EOF'
#!/usr/bin/env bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "▶ apt update + 最小化 build tools install (Rosetta 下慢, 只装必要)"
apt-get update -qq 2>&1 | tail -2
# === mmx-patch: build-linux-gui.sh:50 check_deps 检查 node npm wget file tar ===
# tar 已预装在 ubuntu base, 其他 4 个要装 (g++/make/python3 是 build 工具)
apt-get install -y --no-install-recommends \
    p7zip-full dpkg-dev gcc g++ make python3 ca-certificates curl wget file 2>&1 | tail -2

# mmx-patch: 让后续 apt 也走代理 (apt 不读 http_proxy env, 要 /etc/apt/apt.conf.d/00proxy)
cat > /etc/apt/apt.conf.d/00proxy <<EOF
Acquire::http::Proxy "http://host.docker.internal:6864";
Acquire::https::Proxy "http://host.docker.internal:6864";
EOF

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

# === mmx-patch: postinstall 经常 silent 失败, 显式验证 binary ===
# 之前 2 次 build 都卡在 "[ERROR] 找不到 Linux Electron 43 binary" — npm 装完了但 binary 没下
ELECTRON_DIST=/tmp/elec43/node_modules/electron/dist/electron
if [ ! -x "$ELECTRON_DIST" ]; then
    echo "[mmx-fix] postinstall 没下 binary, 手动重跑 install.js"
    cd /tmp/elec43/node_modules/electron
    # 手动调用 @electron/get (走 HTTPS_PROXY)
    ELECTRON_GET_USE_PROXY=1 HTTPS_PROXY="$https_proxy" HTTP_PROXY="$http_proxy" \
        node install.js 2>&1 | tail -10
    cd /work
    if [ ! -x "$ELECTRON_DIST" ]; then
        echo "[ERROR] 手动 install.js 也没下成功, 退出"
        ls -la /tmp/elec43/node_modules/electron/ 2>&1 | head -10
        exit 1
    fi
fi
echo "✓ electron binary: $(file $ELECTRON_DIST | cut -d: -f2)"

echo "▶ build libmmmx shim (Mac clang 不认 .symver, 必须 Linux gcc)"
mkdir -p /work/lib
gcc -shared -fPIC -nostdlib -o /work/lib/libfmod_shim.so \
    /work/src/libmmmx-shim.c -Wl,--version-script=/work/src/libmmmx-shim.map
nm -D /work/lib/libfmod_shim.so | grep fmod

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
fi
chmod +x "$CONTAINER_CMD_FILE"
echo "[prep] container command file: $CONTAINER_CMD_FILE"

# --- 4) docker run ---
# === mmx-patch: --platform linux/amd64 + 镜像复用 ===
# 关键: 不要每次都从 ubuntu:24.04 起 + apt install (慢 5-10 分钟)
# 推荐流程:
#   1) 第一次: ./scripts/build-in-container.sh --save-image=mmx-build-env
#   2) 之后:   ./scripts/build-in-container.sh --from-image=mmx-build-env --skip-deps
#
# 镜像里会缓存: apt 装好的 build tools + node 22 + electron 43.1.0
# 跳过的: Stage A+B (asar rewrite) + Stage C (deb) — 每次都跑, 因为产物会变

if [ -n "$FROM_IMAGE" ]; then
    DOCKER_IMAGE="$FROM_IMAGE"
    echo "[run] 用 FROM_IMAGE=$FROM_IMAGE (跳过 apt install, 直入 rebuild)"
else
    DOCKER_IMAGE="ubuntu:$UBUNTU_TAG"
    echo "[run] 用 base $DOCKER_IMAGE (会装 apt + node + electron)"
fi

DOCKER_OPTS=(
    --platform linux/amd64
    -v "$PROJECT_ROOT:/work"
    -v "$CONTAINER_CMD_FILE:/tmp/container-cmd.sh"
    -w /work
    -e "DEBIAN_FRONTEND=noninteractive"
    # === mmx-patch: 透传系统代理 (Mac 127.0.0.1:6864) ===
    -e "http_proxy=http://host.docker.internal:6864"
    -e "https_proxy=http://host.docker.internal:6864"
    -e "HTTP_PROXY=http://host.docker.internal:6864"
    -e "HTTPS_PROXY=http://host.docker.internal:6864"
    -e "no_proxy=127.0.0.1,localhost,*.local"
    -e "NO_PROXY=127.0.0.1,localhost,*.local"
    -i
    "$DOCKER_IMAGE"
)

if [ -n "$KEEP_CONTAINER" ]; then
    DOCKER_OPTS=(--name "mmx-build-$$" "${DOCKER_OPTS[@]}")
fi

echo "[run] 容器内 5 步: apt install (5-10min) → node + electron (3-5min) → shim build (5s) → Stage A+B rebuild (10-15min) → Stage C deb (10-15min)"
echo "[run] 总计约 30-50 分钟 (qemu 模拟 amd64 慢)"
echo

docker run "${DOCKER_OPTS[@]}" bash /tmp/container-cmd.sh
RC=$?

# --- 5) 可选: commit 到镜像 ---
if [ -n "$SAVE_IMAGE" ] && [ $RC -eq 0 ]; then
    # 找刚跑完的容器 (通过 image 找最近的)
    CID=$(docker ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null | grep "$DOCKER_IMAGE" | head -1 | awk '{print $1}')
    if [ -n "$CID" ]; then
        echo
        echo "[save] commit container $CID → image $SAVE_IMAGE"
        docker commit "$CID" "$SAVE_IMAGE" 2>&1 | tail -3
        echo "[save] 镜像列表:"
        docker images | grep -E "$(basename $SAVE_IMAGE|head -1)|REPOSITORY" | head -5
        echo "[save] 下次用: $0 --from-image=$SAVE_IMAGE --skip-deps"
    fi
fi

echo
echo "✅ 容器内 build 完成 (exit=$RC)"
ls -lh "$PROJECT_ROOT/dist/" 2>/dev/null || echo "(no dist/ — see container log above)"

# 清理临时文件
rm -f "$CONTAINER_CMD_FILE"
