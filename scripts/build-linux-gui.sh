#!/usr/bin/env bash
# build-linux-gui.sh — 把 MiniMax Code Windows NSIS installer 改成 Linux GUI 客户端
#
# 输入: MiniMax-Code-Setup-x.x.x.exe (Windows NSIS)
# 输出: unpacked/app-64/resources/app.asar (Linux 可用版本)
#       + unpacked/app-64/resources/resources/* (运行时资源)
#
# 原理：
#   1. NSIS 自解压 → unpacked/app-64/ 含完整 Electron + Windows asar
#   2. 用 @electron/asar 解 asar 到 /tmp/mmx-app-v3/
#   3. 注入 4 个 Linux native binding（替代 Windows .node）
#   4. Patch asar JS（GPU disable / open-external / tray / deeplink / mcode-tools）
#   5. 重新 pack asar，替换 unpacked/app-64/resources/app.asar
#
# 依赖：
#   - Linux x86_64
#   - node 22+ (任意 LTS，npm + node-gyp)
#   - internet + http_proxy (用于下载 prebuilds)
#   - Linux Electron 43.1.0 (从任意 electron 43 安装位置复用)
#
# 一次性需要 root 装：gcc g++ make python3 libappindicator3-1 (optional for tray)

set -e

# ============ 配置 ============
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
UNPACK_DIR="$PROJECT_ROOT/unpacked/app-64"
RESOURCES_DIR="$UNPACK_DIR/resources"
APP_ASAR="$RESOURCES_DIR/app.asar"
APP_ASAR_BAK="$RESOURCES_DIR/app.asar.orig"
APP_ASAR_UNPACKED="$RESOURCES_DIR/app.asar.unpacked"

WORK_DIR="/tmp/mmx-app-v3"
LOG_DIR="/tmp/mmx-logs"
NATIVE_BUILD_DIR="/tmp/mmx-linux-install/native-builds"

# Linux Electron 43.1.0 路径（外部依赖，需要预先安装）
ELEC43_DIR="${ELEC43_DIR:-/home/weekbin/Works/repositories/orca/node_modules/.pnpm/electron@43.1.0/node_modules/electron}"
ELECTRON_BIN="$ELEC43_DIR/dist/electron"

# 工具
ASAR_TOOL="/tmp/asar-tool/node_modules/.bin/asar"
NPM="npm"

# 代理
export http_proxy="${http_proxy:-http://127.0.0.1:20172/}"
export https_proxy="${https_proxy:-http://127.0.0.1:20172/}"

# ============ 检查 ============
log() { echo -e "\033[1;36m[$(date +%H:%M:%S)]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

check_deps() {
  log "检查依赖..."
  for cmd in node npm wget file tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "缺少命令: $cmd"
      exit 1
    fi
  done
  if [ ! -x "$ELECTRON_BIN" ]; then
    err "找不到 Linux Electron 43 binary: $ELECTRON_BIN"
    err "请先在别处 npm install electron@43.1.0，然后设置 ELEC43_DIR"
    exit 1
  fi
  log "✓ 依赖 OK (Electron: $($ELECTRON_BIN --version))"
}

install_asar_tool() {
  if [ ! -x "$ASAR_TOOL" ]; then
    log "安装 @electron/asar@4.3.0 (修复 typebox 丢文件 bug 的版本)..."
    mkdir -p /tmp/asar-tool
    (cd /tmp/asar-tool && npm init -y >/dev/null && npm install @electron/asar@4.3.0 --no-save >/dev/null)
  fi
  log "✓ asar tool: $ASAR_TOOL"
}

# ============ 步骤 1: 解 NSIS / 用现有 unpacked ============
ensure_unpacked() {
  if [ ! -d "$UNPACK_DIR" ] || [ ! -f "$APP_ASAR" ]; then
    err "找不到 $UNPACK_DIR 或 $APP_ASAR"
    err "请先用 7z/nsis 解包 MiniMax-Code-Setup-*.exe 到 $PROJECT_ROOT/unpacked/"
    exit 1
  fi
  if [ ! -f "$APP_ASAR_BAK" ]; then
    log "备份原 asar → app.asar.orig"
    cp "$APP_ASAR" "$APP_ASAR_BAK"
  fi
  log "✓ unpacked/ + app.asar ready"
}

# ============ 步骤 2: 解 asar ============
extract_asar() {
  log "解 asar → $WORK_DIR ..."
  rm -rf "$WORK_DIR"
  # === mmx-patch v2: NSIS 自带的 app.asar.unpacked/ (38MB, 含 pi-tui Linux JS + Windows .node)
  # 必须 cp 到 app.asar.orig.unpacked/ (asar extract 期望的位置), 否则 asar 4.3.0 extractAll
  # 会对每个 unpacked 文件 fs.readFileSync('app.asar.orig.unpacked/...') ENOENT, 整批中断
  # (上一版用 || true 掩盖错误, 导致 jszip / pi-tui 大量文件 extract 失败)
  if [ -d "$RESOURCES_DIR/app.asar.unpacked" ]; then
    log "复制 NSIS 自带 asar.unpacked → asar.orig.unpacked (38MB) ..."
    rm -rf "$RESOURCES_DIR/app.asar.orig.unpacked"
    cp -a "$RESOURCES_DIR/app.asar.unpacked" "$RESOURCES_DIR/app.asar.orig.unpacked"
  fi
  "$ASAR_TOOL" extract "$APP_ASAR_BAK" "$WORK_DIR" || true
  log "✓ asar 解包 ($(find $WORK_DIR -type f | wc -l) 个文件)"
}

# ============ 步骤 3: 装 4 个 native binding 的 Linux 版本 ============
build_ripgrep() {
  log "[1/4] 装 @vscode/ripgrep-linux-x64 ..."
  if [ ! -d "$WORK_DIR/node_modules/@vscode/ripgrep-linux-x64/bin" ]; then
    mkdir -p "$NATIVE_BUILD_DIR"
    (cd "$NATIVE_BUILD_DIR" && $NPM init -y >/dev/null 2>&1 || true)
    (cd "$NATIVE_BUILD_DIR" && $NPM install @vscode/ripgrep@1.18.0 --no-save >/dev/null 2>&1)
    cp -r "$NATIVE_BUILD_DIR/node_modules/@vscode/ripgrep-linux-x64" \
          "$WORK_DIR/node_modules/@vscode/"
  fi
  log "✓ ripgrep: $(file $WORK_DIR/node_modules/@vscode/ripgrep-linux-x64/bin/rg | cut -d: -f2)"
}

build_libnut() {
  log "[2/4] 装 @nut-tree-fork/libnut-linux (N-API, ABI-stable) ..."
  if [ ! -f "$WORK_DIR/node_modules/@nut-tree/libnut-linux/build/Release/libnut.node" ]; then
    (cd "$NATIVE_BUILD_DIR" && $NPM install @nut-tree-fork/libnut >/dev/null 2>&1)
    mkdir -p "$WORK_DIR/node_modules/@nut-tree/libnut-linux/build/Release"
    cp "$NATIVE_BUILD_DIR/node_modules/@nut-tree-fork/libnut-linux/build/Release/libnut.node" \
       "$WORK_DIR/node_modules/@nut-tree/libnut-linux/build/Release/libnut.node"
  fi
  log "✓ libnut: $(file $WORK_DIR/node_modules/@nut-tree/libnut-linux/build/Release/libnut.node | cut -d: -f2)"
}

build_better_sqlite3() {
  # === mmx-patch: 从源码 rebuild (匹配 build 机器的 GLIBC, 兼容 jammy 2.35/focal 2.31) ===
  # 不再用 v12.12.0 NMV 148 prebuilt (那个是 Ubuntu 24.04 GLIBC 2.39 build 的)
  log "[3/4] Rebuild better-sqlite3 from source for current GLIBC ..."
  if [ ! -f "$WORK_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]; then
    mkdir -p "$NATIVE_BUILD_DIR"
    (cd "$NATIVE_BUILD_DIR" && $NPM init -y 2>&1 | tail -2)
    # 装 @electron/rebuild — 错误不能屏蔽, 否则后续会 MODULE_NOT_FOUND
    (cd "$NATIVE_BUILD_DIR" && $NPM install @electron/rebuild 2>&1 | tail -3)
    if [ ! -x "$NATIVE_BUILD_DIR/node_modules/.bin/electron-rebuild" ]; then
        err "@electron/rebuild 装上了但 binary 缺失, 用 npx 兜底"
    fi
    # 装 better-sqlite3 源码 (用 --ignore-scripts 跳过 prebuilt install)
    # === mmx-patch: v12.10.1 不是 v11.10.0 ===
    # v11.10.0 用旧 V8 API (v8::External::Value() 无参), electron 43 的 V8 要求
    # v8::External::Value(ExternalPointerTypeTag tag) 带参. 编译报:
    #   error: no matching function for call to 'v8::External::Value()'
    # v12.10.1 修了 V8 API 兼容 (AGENTS.md §4.1 也推荐 12.10.1)
    (cd "$NATIVE_BUILD_DIR" && $NPM install better-sqlite3@12.10.1 --no-save --ignore-scripts 2>&1 | tail -2)
    # 复制源码到 WORK_DIR (asar 内需要)
    mkdir -p "$WORK_DIR/node_modules/better-sqlite3"
    cp -r "$NATIVE_BUILD_DIR/node_modules/better-sqlite3"/* "$WORK_DIR/node_modules/better-sqlite3/" 2>/dev/null || true
    # Rebuild for Electron 43 (NMV 148) — 不用 | tail -3, 失败要看真错误
    set +e
    if [ -x "$NATIVE_BUILD_DIR/node_modules/.bin/electron-rebuild" ]; then
        (cd "$NATIVE_BUILD_DIR" && node node_modules/.bin/electron-rebuild \
          -v 43.1.0 -e "$ELEC43_DIR" -f -w better-sqlite3)
    else
        # 用 npx 兜底 (会先 install @electron/rebuild, 再执行)
        (cd "$NATIVE_BUILD_DIR" && npx --yes @electron/rebuild \
          -v 43.1.0 -e "$ELEC43_DIR" -f -w better-sqlite3)
    fi
    RC=$?
    set -e
    if [ $RC -ne 0 ]; then
      err "electron-rebuild 失败 rc=$RC, 不继续 (会 cp 失败)"
      return 1
    fi
    # 复制 rebuild 后的 .node 到 WORK_DIR
    mkdir -p "$WORK_DIR/node_modules/better-sqlite3/build/Release"
    cp "$NATIVE_BUILD_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node" \
       "$WORK_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  fi
  log "✓ better-sqlite3: $(file $WORK_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node | cut -d: -f2)"
}

build_node_pty() {
  log "[4/4] Rebuild node-pty v1.0.0 for Electron 43 ABI via @electron/rebuild ..."
  (cd "$NATIVE_BUILD_DIR" && $NPM install @electron/rebuild node-pty@1.0.0 --save-dev --ignore-scripts >/dev/null 2>&1)
  (cd "$NATIVE_BUILD_DIR" && node node_modules/.bin/electron-rebuild \
    -v 43.1.0 -e "$ELEC43_DIR" -f -w node-pty 2>&1 | tail -5)
  mkdir -p "$WORK_DIR/node_modules/node-pty/build/Release"
  cp "$NATIVE_BUILD_DIR/node_modules/node-pty/build/Release/pty.node" \
     "$WORK_DIR/node_modules/node-pty/build/Release/pty.node"
  log "✓ pty: $(file $WORK_DIR/node_modules/node-pty/build/Release/pty.node | cut -d: -f2)"
}

# ============ 步骤 4: Patch asar JS ============
patch_js() {
  log "Patch asar JS (GPU / open-external / tray / deeplink / mcode-tools / capturePage) ..."

  # --- index.js: GPU disable + platform fallback ---
  python3 << 'PYEOF'
import re
p = "/tmp/mmx-app-v3/dist/main/index.js"
s = open(p).read()
# 1) GPU disable (idempotent)
if "[mmx-patch] disableHardwareAcceleration" not in s:
    s = s.replace(
        "const electron_1 = require(\"electron\");",
        "const electron_1 = require(\"electron\");\n// === mmx-patch: Wine/Electron GPU compat ===\n"
        "try { electron_1.app.disableHardwareAcceleration(); } catch(e) {}\n"
        "try { electron_1.app.commandLine.appendSwitch('disable-gpu'); } catch(e) {}\n"
        "try { electron_1.app.commandLine.appendSwitch('in-process-gpu'); } catch(e) {}\n"
        "try { electron_1.app.commandLine.appendSwitch('disable-features', 'UseOzonePlatform'); } catch(e) {}\n"
    )
# 2) platform fallback
s = re.sub(
    r"process\.platform\s*===\s*['\"]linux['\"]",
    "process.platform === 'linux' || 'linux'",
    s,
)
open(p, "w").write(s)
print("[ok] index.js patched")
PYEOF

  # --- window.ipc.js: add child_process import for OPEN_EXTERNAL spawn ---
  # 也 inject 健壮的 OPEN_EXTERNAL handler (用 shell.openExternal + spawn fallback)
  python3 << 'PYEOF'
p = "/tmp/mmx-app-v3/dist/main/ipc/window.ipc.js"
s = open(p).read()
# 1) Add child_process import if missing
if "node:child_process" not in s and "node_child_process" not in s:
    s = s.replace(
        'const electron_1 = require("electron");\nconst constants_1',
        'const electron_1 = require("electron");\nconst node_child_process_1 = require("node:child_process");\nconst constants_1',
    )
# 2) Replace child_process.spawn with node_child_process_1.spawn (idempotent if already done)
s = s.replace("child_process.spawn(", "node_child_process_1.spawn(")
open(p, "w").write(s)
print("[ok] window.ipc.js patched (child_process import + spawn)")
PYEOF

  # --- window.ipc.js: 用健壮的 OPEN_EXTERNAL handler 替换 hardcode 路径 ---
  python3 << 'PYEOF'
import re
p = "/tmp/mmx-app-v3/dist/main/ipc/window.ipc.js"
s = open(p).read()

# 检测是否已经 patch (idempotent)
if "default browser via xdg-mime" in s:
    print("[skip] window.ipc.js OPEN_EXTERNAL already patched (xdg-mime version)")
else:
    # 找到 OPEN_EXTERNAL handler 里 hardcode 的 candidates block
    pattern = r"(electron_1\.ipcMain\.handle\(constants_1\.IPC_CHANNELS\.OPEN_EXTERNAL, async \(_, url\) => \{\s*try \{)\s*// mmx-final[\s\S]*?return \{ success: true \};\s*\}\s*await \(0, open_external_target_1\.openExternalTarget\)\(url\);"
    new_handler = r"""\1
        if ((process.platform === 'linux' || process.platform === 'win32')) {
            // === mmx-patch: Linux 浏览器唤起 (系统 default 优先, 多层 fallback) ===
            // 1) shell.openExternal (Electron 内置)
            // 2) xdg-mime → .desktop → Exec= parse → spawn (freedesktop 标准 default browser)
            // 3) xdg-open (PATH lookup)
            // 4) PATH + hardcode browser list
            try {
                const fs = require('node:fs');
                const pathMod = require('node:path');
                const { execFile: execFileCb } = require('node:child_process');
                const { promisify } = require('node:util');
                const execFileP = promisify(execFileCb);
                const PATH_DIRS = (process.env.PATH || '/usr/local/bin:/usr/bin:/bin').split(':');
                const findInPath = (name) => {
                    for (const dir of PATH_DIRS) {
                        const p = pathMod.join(dir, name);
                        try { if (fs.statSync(p).isFile()) return p; } catch {}
                    }
                    return null;
                };
                // .desktop Exec= 字段 parser (处理 %u/%U/%F 替换 url, 处理引号)
                const parseDesktopExec = (execLine, url) => {
                    const tokens = [];
                    let cur = ''; let inQuote = false;
                    for (let i = 0; i < execLine.length; i++) {
                        const c = execLine[i];
                        if (c === '"' || c === "'") { inQuote = !inQuote; continue; }
                        if (c === ' ' && !inQuote) { if (cur) { tokens.push(cur); cur = ''; } }
                        else cur += c;
                    }
                    if (cur) tokens.push(cur);
                    const args = tokens.slice(1).map(t => (t === '%u' || t === '%U' || t === '%F' || t === '%f') ? url : t);
                    return { bin: tokens[0], args };
                };
                // 找 .desktop 文件
                const findDesktop = (desktopName) => {
                    if (!desktopName) return null;
                    const dirs = [
                        `${process.env.HOME || '/root'}/.local/share/applications`,
                        '/usr/local/share/applications',
                        '/usr/share/applications',
                        '/var/lib/flatpak/exports/share/applications',
                        '/var/lib/snapd/desktop/applications',
                    ];
                    for (const dir of dirs) {
                        const p = pathMod.join(dir, desktopName);
                        try { if (fs.statSync(p).isFile()) return p; } catch {}
                    }
                    return null;
                };
                // 通过 freedesktop 查 default browser
                const queryDefault = async () => {
                    for (const mime of ['x-scheme-handler/https', 'text/html', 'application/xhtml+xml']) {
                        try {
                            const { stdout } = await execFileP('xdg-mime', ['query', 'default', mime], {timeout: 2000});
                            const name = stdout.trim();
                            if (name && name.endsWith('.desktop')) {
                                const p = findDesktop(name);
                                if (p) return { name, path: p, via: 'xdg-mime' };
                            }
                        } catch {}
                    }
                    try {
                        const { stdout } = await execFileP('xdg-settings', ['get', 'default-web-browser'], {timeout: 2000});
                        const name = stdout.trim();
                        if (name && name.endsWith('.desktop')) {
                            const p = findDesktop(name);
                            if (p) return { name, path: p, via: 'xdg-settings' };
                        }
                    } catch {}
                    try {
                        const { stdout } = await execFileP('update-alternatives', ['--query', 'x-www-browser'], {timeout: 2000});
                        const m = stdout.match(/Value:\\s*(\\S+)/);
                        if (m) return { name: pathMod.basename(m[1]), path: m[1], via: 'alternatives' };
                    } catch {}
                    return null;
                };
                // spawn helper - await 真正确认成功
                const trySpawn = (bin, args) => new Promise((resolve) => {
                    try {
                        const child = node_child_process_1.spawn(bin, args, {
                            detached: true, stdio: 'ignore',
                            env: Object.assign({}, process.env, {
                                DISPLAY: process.env.DISPLAY || ':0',
                                XAUTHORITY: process.env.XAUTHORITY || '',
                                DBUS_SESSION_BUS_ADDRESS: process.env.DBUS_SESSION_BUS_ADDRESS || '',
                                XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR || '',
                                HOME: process.env.HOME || '',
                            }),
                        });
                        let resolved = false;
                        const done = (ok) => { if (!resolved) { resolved = true; resolve(ok); } };
                        child.on('error', err => { console.log('[mmx-shell] spawn err:', bin, err.message); done(false); });
                        child.on('spawn', () => { console.log('[mmx-shell] spawned:', bin, url); child.unref(); done(true); });
                        setTimeout(() => done(false), 1500);
                    } catch (e) { resolve(false); }
                };
                // 1) shell.openExternal 优先
                try {
                    await electron_1.shell.openExternal(url);
                    console.log('[mmx-shell] openExternal ok:', url);
                    return { success: true, browser: 'shell.openExternal' };
                } catch (shellErr) { console.log('[mmx-shell] openExternal failed:', shellErr.message); }
                // 2) 系统 default browser via xdg-mime
                const def = await queryDefault();
                if (def) {
                    try {
                        const content = fs.readFileSync(def.path, 'utf8');
                        const m = content.match(/^Exec=([^\\n]+)/m);
                        if (m) {
                            const { bin, args } = parseDesktopExec(m[1], url);
                            console.log('[mmx-shell] default browser:', def.name, 'via', def.via, '->', bin);
                            const ok = await trySpawn(bin, args);
                            if (ok) return { success: true, browser: bin, via: def.via, desktop: def.name };
                        }
                    } catch (e) { console.log('[mmx-shell] .desktop parse failed:', e.message); }
                }
                // 3) xdg-open fallback
                const xdgOpen = findInPath('xdg-open');
                if (xdgOpen) {
                    const ok = await trySpawn(xdgOpen, [url]);
                    if (ok) return { success: true, browser: xdgOpen, via: 'xdg-open-fallback' };
                }
                // 4) hardcode + PATH browser list (last resort)
                const HARDCODED = {
                    'chromium':  ['/snap/bin/chromium', '/var/lib/flatpak/exports/bin/org.chromium.Chromium', '/usr/bin/chromium', '/usr/bin/chromium-browser'],
                    'chrome':    ['/opt/google/chrome/chrome', '/usr/bin/google-chrome-stable', '/usr/bin/google-chrome'],
                    'firefox':   ['/snap/bin/firefox', '/var/lib/flatpak/exports/bin/org.mozilla.firefox', '/usr/bin/firefox'],
                    'brave':     ['/usr/bin/brave-browser-stable', '/usr/bin/brave-browser'],
                    'edge':      ['/usr/bin/microsoft-edge-stable', '/usr/bin/microsoft-edge'],
                };
                const browserFlags = {
                    'chrome':    ['--new-window', url],
                    'chromium':  ['--new-window', url],
                    'firefox':   ['--new-tab', url],
                    'brave':     ['--new-window', url],
                    'edge':      ['--new-window', url],
                };
                const tried = new Set();
                const tryList = [];
                for (const [name, args] of Object.entries(browserFlags)) {
                    const inPath = findInPath(name === 'chrome' ? 'google-chrome' : name);
                    if (inPath && !tried.has(inPath)) { tried.add(inPath); tryList.push([inPath, args]); }
                    for (const hp of HARDCODED[name] || []) {
                        try { if (fs.statSync(hp).isFile() && !tried.has(hp)) { tried.add(hp); tryList.push([hp, args]); } } catch {}
                    }
                }
                for (const [bin, args] of tryList) {
                    const ok = await trySpawn(bin, args);
                    if (ok) return { success: true, browser: bin, via: 'hardcode-fallback' };
                }
                console.error('[mmx-shell] no browser found, tried:', tryList.map(c => c[0]).join(', '));
                return { success: false, error: 'no_browser_found', tried: tryList.map(c => c[0]) };
            } catch (e) {
                console.error('[mmx-shell] openExternal handler failed:', e);
                return { success: false, error: String(e && e.message || e) };
            }
        }
        await (0, open_external_target_1.openExternalTarget)(url);"""
    s = re.sub(pattern, new_handler, s, count=1, flags=re.DOTALL)
    if "default browser via xdg-mime" in s:
        open(p, "w").write(s)
        print("[ok] window.ipc.js OPEN_EXTERNAL handler patched (shell+xdg-mime+.desktop Exec= parse+xdg-open+hardcode)")
    else:
        print("[warn] window.ipc.js OPEN_EXTERNAL pattern not matched, manual review needed")
PYEOF

  # --- tray: Linux skip ---
  python3 << 'PYEOF'
p = "/tmp/mmx-app-v3/dist/main/modules/tray/index.js"
s = open(p).read()
if "Skipping tray creation on Linux" not in s:
    s = s.replace(
        "    try {\n        const icon = getTrayIcon();",
        "    try {\n        // === mmx-patch: Linux 跳过 tray（缺 libappindicator） ===\n"
        "        if (process.platform === 'linux') {\n"
        "            console.log('[Tray] Skipping tray creation on Linux');\n"
        "            return null;\n"
        "        }\n        const icon = getTrayIcon();",
    )
open(p, "w").write(s)
print("[ok] tray/index.js patched")
PYEOF

  # --- deeplink: Linux silent register ---
  python3 << 'PYEOF'
p = "/tmp/mmx-app-v3/dist/main/modules/deeplink/index.js"
s = open(p).read()
if "mmx-silent" not in s:
    s = s.replace(
        "console.warn(`[DeepLink] Failed to register dev protocol handler",
        "console.log(`[DeepLink] (mmx-silent) Dev protocol handler not registered"
    )
    s = s.replace(
        "console.warn(`[DeepLink] Failed to reclaim macOS dev protocol handler",
        "console.log(`[DeepLink] (mmx-silent) Dev protocol handler not reclaimed"
    )
    # Wrap setAsDefaultProtocolClient with try-catch on linux
    s = s.replace(
        "        const ok = electron_1.app.setAsDefaultProtocolClient(exports.PROTOCOL_NAME, process.execPath);",
        "        try { electron_1.app.setAsDefaultProtocolClient(exports.PROTOCOL_NAME, process.execPath); } catch(e) { console.log('[DeepLink] (mmx-silent) prod register err:', e.message); }"
    )
open(p, "w").write(s)
print("[ok] deeplink/index.js patched")
PYEOF

  # --- native-sqlite-env: 整文件替换为 Linux port 版 ---
  # 3.0.73 的 stock 文件跟 3.0.67 差异大, 逐段 sed 会留半截引用
  # (导出 resolveLocalRuntimeRepoRoot 但没定义 → module load ReferenceError → 主进程起不来)。
  # src/native-sqlite-env.js.linux 是完整版: 优先把 MAVIS_SQLITE3_MODULE_PATH 指到
  # asar.unpacked 里已注入的 Linux better-sqlite3, 跳过 dev 的 prebuild-install 流程。
  cp "$PROJECT_ROOT/src/native-sqlite-env.js.linux" /tmp/mmx-app-v3/dist/main/modules/local-runtime/native-sqlite-env.js
  print_msg="[ok] native-sqlite-env.js replaced (linux port)"
  echo "$print_msg"

  # --- @mavis/local-runtime better-sqlite3-loader: 允许 asar.unpacked 路径 ---
  # stock 版 isAsarUnpackedPath 检查会拒绝 asar.unpacked 下的 override path,
  # utility subprocess 回退 require('better-sqlite3') → handshake failed。
  cp "$PROJECT_ROOT/src/better-sqlite3-loader.js.linux" /tmp/mmx-app-v3/node_modules/@mavis/local-runtime/dist/persistence/better-sqlite3-loader.js
  echo "[ok] @mavis/local-runtime better-sqlite3-loader.js replaced (linux port)"

  # --- local-runtime/index.js: getPromptConfigKey 强制 packaged 分支 ---
  # 手动启 electron <app.asar> 时 app.isPackaged=false, stock 走 dev 分支
  # require asar 里不存在的 scripts/prompt-config-key-package.cjs → 抛错被吞
  # → "utility runtime initialization handshake failed" → LocalRuntime 起不来。
  # asar 内 public/assets/img/{breakDown,computer_use}.png 有 maKs/mbKs 私 chunk,
  # packaged:true 能读; 读不到降级 undefined (init 里该字段可选)。
  python3 << 'PYEOF'
p = "/tmp/mmx-app-v3/dist/main/modules/local-runtime/index.js"
s = open(p).read()
if "mmx-patch: getPromptConfigKey packaged on linux" not in s:
    old = "getPromptConfigKey: () => (0, prompt_config_key_1.resolveDesktopPromptConfigKey)({ packaged: electron_1.app.isPackaged, appPath: electron_1.app.getAppPath() }),"
    new = """getPromptConfigKey: () => {
        try {
            // === mmx-patch: getPromptConfigKey packaged on linux ===
            return (0, prompt_config_key_1.resolveDesktopPromptConfigKey)({ packaged: true, appPath: electron_1.app.getAppPath() });
        }
        catch (e) {
            logger_1.default.warn(`[LocalRuntime] prompt config key unavailable (mmx-patch): ${String(e)}`);
            return undefined;
        }
    },"""
    if old in s:
        s = s.replace(old, new)
        open(p, "w").write(s)
        print("[ok] local-runtime/index.js getPromptConfigKey patched")
    else:
        print("[warn] getPromptConfigKey pattern not matched")
else:
    print("[ok] local-runtime/index.js already patched")
PYEOF

  # --- utility-process-manager: handshake catch 记录真实异常 ---
  # stock `catch {}` 把 init 构造异常 (如 prompt-config-key) 吞成笼统的 handshake failed。
  python3 << 'PYEOF'
p = "/tmp/mmx-app-v3/dist/main/modules/local-runtime/utility/utility-process-manager.js"
s = open(p).read()
if "root cause" not in s:
    old = """            catch {
                clearStallTimer();
                const latched = this.countInitFailure();
                const message = 'utility runtime initialization handshake failed';
                this.discardChild(child, latched ? { message, reasonCode: 'handshake_failed' } : null, startupToken);
                settle(false);
                logger.error(`[UtilityRuntime] ${message}`);"""
    new = """            catch (handshakeErr) {
                clearStallTimer();
                const latched = this.countInitFailure();
                const message = 'utility runtime initialization handshake failed';
                this.discardChild(child, latched ? { message, reasonCode: 'handshake_failed' } : null, startupToken);
                settle(false);
                logger.error(`[UtilityRuntime] ${message}; root cause: ${handshakeErr && (handshakeErr.stack || handshakeErr.message || String(handshakeErr))}`);"""
    if old in s:
        s = s.replace(old, new)
        open(p, "w").write(s)
        print("[ok] utility-process-manager.js handshake catch logs root cause")
    else:
        print("[warn] handshake catch pattern not matched")
else:
    print("[ok] utility-process-manager.js already patched")
PYEOF

  # --- mcode-tools: demote integration unavailable ---
  python3 << 'PYEOF'
p = "/tmp/mmx-app-v3/dist/main/modules/mcode-tools/index.js"
s = open(p).read()
if "mmx-silent" not in s:
    s = s.replace(
        "logger_1.default.warn(`[mcode-tools] integration unavailable",
        "logger_1.default.info(`[mcode-tools] integration unavailable (mmx-silent)",
    )
open(p, "w").write(s)
print("[ok] mcode-tools/index.js patched")
PYEOF

  # --- loginWindow + archonChatWindow: capturePage hook ---
  python3 << 'PYEOF'
import re
for path, ready_label in [
    ("/tmp/mmx-app-v3/dist/main/windows/loginWindow.js", "login-ui"),
    ("/tmp/mmx-app-v3/dist/main/windows/archonChatWindow.js", "mainwindow"),
]:
    s = open(path).read()
    if "mmx-patch] capturePage" in s:
        continue
    # 在 ready-to-show 回调内插入 capturePage
    pattern = r"(window\.once\('ready-to-show',\s*\(\)\s*=>\s*\{[^}]*?window\?\.focus\(\);)([^}]*?\}\)\);)"
    def replacer(m):
        head, tail = m.group(1), m.group(2)
        inject = """

        // === mmx-patch: capturePage for verification ===
        try {
            const captureOnce = (label) => setTimeout(() => {
                window.webContents.capturePage().then((img) => {
                    const fs = require('fs');
                    const path = require('path');
                    const outDir = '/tmp/mmx-logs';
                    if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
                    const stamp = Date.now();
                    fs.writeFileSync(path.join(outDir, `mmx-${label}-${stamp}.png`), img.toPNG());
                    console.log(`[mmx-patch] ${label} captured to`, `/tmp/mmx-logs/mmx-${label}-${stamp}.png`);
                }).catch((e) => console.error(`[mmx-patch] ${label} capturePage failed:`, e));
            }, 3000);
            captureOnce('__LABEL__');
        } catch (e) { console.error('[mmx-patch] capturePage setup failed:', e); }"""
        return head + inject.replace("__LABEL__", ready_label) + tail
    s2 = re.sub(pattern, replacer, s, count=1, flags=re.DOTALL)
    if s2 == s:
        print(f"[warn] {path}: pattern not matched")
    else:
        open(path, "w").write(s2)
        print(f"[ok] {path}: capturePage hook injected")
PYEOF

  log "✓ JS patches applied"
}

# ============ 步骤 5: Repack asar ============
pack_asar() {
  log "Repack asar → $APP_ASAR (preserving unpacked markers from orig) ..."
  # === mmx-patch v3: 原版 asar 有 709 个 unpacked markers (jszip/pi-tui/better-sqlite3/node-pty/libnut/...).
  # 上游脚本用 'asar pack' (无 --unpack) → marker 全部丢失 → 运行时 unpacked 文件找不到。
  # 用 tools/repack-asar.cjs (仓库内置 helper), 从 app.asar.orig 读 markers 保留,
  # set lookup (O(1)) 替代 minimatch glob 匹配 (O(n) + 40KB pattern 巨慢)
  if [ ! -f "$PROJECT_ROOT/tools/repack-asar.cjs" ]; then
    log "[error] tools/repack-asar.cjs 不存在, fall back to 标准 asar pack (会丢 markers)"
    cd "$WORK_DIR"
    "$ASAR_TOOL" pack . "$APP_ASAR" 2>&1 | tail -3
  else
    node "$PROJECT_ROOT/tools/repack-asar.cjs" "$WORK_DIR" "$APP_ASAR" "$APP_ASAR_BAK" 2>&1 | tail -5
  fi
  log "✓ app.asar: $(ls -lh $APP_ASAR | awk '{print $5}')"
}

# ============ 步骤 6: better-sqlite3 的 JS 依赖放进 app.asar.unpacked ============
# MAVIS_SQLITE3_MODULE_PATH 指向 app.asar.unpacked 后, better-sqlite3 的
# require('bindings') 从真实 fs 解析 (不在 asar 虚拟 fs 里), 必须在
# app.asar.unpacked/node_modules/ 下能找到 bindings + file-uri-to-path,
# 否则 utility subprocess require 时 MODULE_NOT_FOUND → 子进程退出 → handshake failed。
inject_better_sqlite3_deps() {
  log "注入 better-sqlite3 JS deps (bindings, file-uri-to-path) → app.asar.unpacked/ ..."
  MMX_ASAR="$APP_ASAR" MMX_DEST="$APP_ASAR_UNPACKED/node_modules" python3 << 'PYEOF'
import json, os, struct, sys

ASAR = os.environ.get("MMX_ASAR")
DEST = os.environ.get("MMX_DEST")
if not ASAR or not os.path.exists(ASAR):
    print(f"[error] app.asar not found: {ASAR}"); sys.exit(1)
if not DEST:
    print("[error] MMX_DEST empty"); sys.exit(1)
PKGS = ["bindings", "file-uri-to-path"]

# 极简 asar reader: 读 4 字节 header size (含 pickle padding), 再读 header json
with open(ASAR, "rb") as f:
    raw = f.read()

def read_pickle_header(buf):
    # asar 磁盘布局 (Chromium Pickle):
    #   [0:4]   sizePickle payload (=4)
    #   [4:8]   headerPickle 总长度 (headerBuf.length)
    #   [8:12]  headerPickle payload 长度
    #   [12:16] JSON 字符串长度 (含 NUL 结尾)
    #   [16:...] JSON + NUL + 4 字节对齐 padding
    header_size = struct.unpack_from("<I", buf, 4)[0]
    json_size = struct.unpack_from("<I", buf, 12)[0]
    return json.loads(buf[16:16 + json_size].rstrip(b"\x00")), 8 + header_size

header, base = read_pickle_header(raw)

files_to_write = {}

def walk(node, prefix):
    for name, ent in (node.get("files") or {}).items():
        p = f"{prefix}/{name}"
        if "files" in ent:
            walk(ent, p)
        else:
            files_to_write[p] = ent

walk(header, "")

count = 0
for pkg in PKGS:
    for p, ent in files_to_write.items():
        if not p.startswith(f"/node_modules/{pkg}/"):
            continue
        if ent.get("unpacked"):
            continue
        rel = p[len("/node_modules/"):]
        out = os.path.join(DEST, rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        off = int(ent["offset"]); size = int(ent["size"])
        with open(out, "wb") as o:
            o.write(raw[base + off: base + off + size])
        count += 1
print(f"[ok] extracted {count} files into {DEST}")
PYEOF
}

# ============ Main ============
main() {
  check_deps
  install_asar_tool
  ensure_unpacked
  extract_asar
  build_ripgrep
  build_libnut
  build_better_sqlite3
  build_node_pty
  patch_js
  pack_asar
  inject_better_sqlite3_deps

  log ""
  log "✅ 全部完成！启动:"
  log "   ./scripts/run-mmx-linux.sh"
}

main "$@"
