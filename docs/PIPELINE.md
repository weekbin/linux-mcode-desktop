# Pipeline: Windows .exe → Linux .deb

**End-to-end record** of how this repo turns a Windows NSIS installer
(`@mmx-agent/electron v3.0.67-inside.44`) into a Linux GUI client
(`minimax-code_<ver>_amd64.deb`).

This doc is the single source of truth for the **full pipeline**,
including the parts that *cannot* run on macOS. Read this before
re-running the build or onboarding a new agent.

> **TL;DR for the impatient**
> ```bash
> # 1) Stage the input
> cp /path/to/MiniMax-Code-Setup-3.0.67-inside.44.exe inputs/
>
> # 2) On macOS: can do unpack + asar rewrite, but NOT native rebuild
> brew install p7zip dpkg
> 7z x inputs/MiniMax-Code-Setup-3.0.67-inside.44.exe -ounpacked
> 7z x 'unpacked/$PLUGINSDIR/app-64.7z' -ounpacked
> # ... restructure into unpacked/app-64/ ... (see §3.1)
>
> # 3) On Linux container (or Ubuntu VM): do the rest
> ELEC43_DIR=/path/to/electron-43 ./scripts/build-in-container.sh
> tools/test-ubuntu.sh 24.04                       # cross-version smoke
> ```
>
> ## 0. Verified end-to-end build (Aug 2026)
>
> The full pipeline was **actually executed on macOS via Docker** (Apple
> Silicon Mac, qemu amd64 emulation), producing a working
> `dist/minimax-code_3.0.67-inside.44_amd64.deb` (163 MB). The end-to-end
> build took ~25 min from scratch under qemu. See `git log` for `3b03c41`
> (the asar 4.3.0 / icon fallback / better-sqlite3 v12.10.1 fixes that
> made this possible).
>
> The container was auto-committed as image `mmx-build-env:latest` for
> rebuild reuse. To rebuild from this image (skipping apt+node+electron):
>
> ```bash
> ./scripts/build-in-container.sh \
>     --from-image=mmx-build-env \
>     --skip-deps \
>     --save-image=mmx-build-env     # save updated image
> ```
>
> Validated deb contents (post-build, all x86-64 ELF, not Windows .node):
>
> | File | Size | Arch |
> |------|------|------|
> | `app.asar.unpacked/.../better-sqlite3/build/Release/better_sqlite3.node` | 2.2 MB | ELF 64-bit LSB, x86-64, dynamically linked |
> | `app.asar.unpacked/.../node-pty/build/Release/pty.node` | 47 KB | ELF 64-bit LSB, x86-64, dynamically linked |
> | `app.asar.unpacked/.../@nut-tree/libnut-linux/build/Release/libnut.node` | 135 KB | ELF 64-bit LSB, x86-64, dynamically linked |
> | `app.asar.unpacked/.../@vscode/ripgrep-linux-x64/bin/rg` | 5.7 MB | ELF 64-bit LSB, x86-64, static-pie |
> | `libfmod_shim.so` (in `/opt/mmx-shared`) | 13.9 KB | ELF 64-bit LSB, x86-64, with `fmod@GLIBC_2.38` + `fmod@GLIBC_2.2.5` versioned symbols |
> | `app.asar` (patched) | 416 MB | contains JS patches (GPU disable, tray, deeplink, open-external, mcode-tools) |

---

## 1. Pipeline overview

```
                ┌─────────────────────┐
                │  Windows .exe       │  ← inputs/
                │  (NSIS installer)   │     370 MB
                └──────────┬──────────┘
                           │ 7z x  (NSIS-3 Unicode)
                ┌──────────▼──────────┐
                │  unpacked/          │  ← 1.6 GB
                │  ├ $PLUGINSDIR/     │     (NSIS overhead)
                │  ├ $R0/             │     (NSIS overhead)
                │  └ app-64.7z        │     (188 MB, inner 7z)
                └──────────┬──────────┘
                           │ 7z x app-64.7z
                ┌──────────▼──────────┐
                │  unpacked/app-64/   │  ← structure consumed
                │  ├ *.dll (Windows)  │     by build scripts
                │  ├ MiniMax Inside Code.exe
                │  └ resources/
                │     ├ app.asar (461 MB)  ← TARGET
                │     └ app.asar.unpacked/ ← TARGET
                └──────────┬──────────┘
                           │
        ┌──────────────────┼──────────────────┐
        │  Stage A (Mac ok)                  │
        │  ─ @electron/asar extract          │
        │  ─ JS patch (6 files)              │
        │  ─ @electron/asar repack           │
        │  → unpacked/app-64/resources/app.asar (424 MB, patched)
        └──────────────────┬──────────────────┘
                           │
        ┌──────────────────▼──────────────────┐
        │  Stage B (Linux only — Mac ❌)      │
        │  ─ better-sqlite3 source rebuild   │
        │  ─ node-pty source rebuild         │
        │  ─ @nut-tree/libnut-linux copy     │
        │  ─ @vscode/ripgrep-linux-x64 copy  │
        │  → /tmp/mmx-app-v3/node_modules/   │
        │     ├── better-sqlite3/build/Release/better_sqlite3.node
        │     ├── node-pty/build/Release/pty.node
        │     ├── @nut-tree/libnut-linux/build/Release/libnut.node
        │     └── @vscode/ripgrep-linux-x64/bin/rg
        └──────────────────┬──────────────────┘
                           │
        ┌──────────────────▼──────────────────┐
        │  Stage C (Mac ok with brew dpkg)   │
        │  ─ Copy Electron 43 → /opt/.../electron
        │  ─ Copy patched app.asar → /opt/.../app
        │  ─ Copy Linux natives → asar.unpacked/
        │  ─ Drop libmmmx shim → /opt/mmx-shared/
        │  ─ Generate DEBIAN/{preinst,postinst,prerm,control}
        │  ─ dpkg-deb --build
        │  → dist/minimax-code_<ver>_amd64.deb (227 MB)
        └─────────────────────────────────────┘
```

**Key split point**: Stage B **must run on Linux**. Stages A and C **can run on macOS** (with brew tools), but the resulting `.deb` is only valid if Stage B was actually executed in a Linux environment.

---

## 2. Input / output conventions

### 2.1 Input — `inputs/`

The Windows NSIS installer goes here. **Gitignored** (`*.exe` + `inputs/`).

| Item | Path | Size | Notes |
|------|------|------|-------|
| Source installer | `inputs/MiniMax-Code-Setup-3.0.67-inside.44.exe` | 370 MB | NSIS-3 Unicode, `CompanyName: MiniMax` |

Naming convention: **drop spaces, keep version**. The original file from
the vendor usually has spaces (`MiniMax Inside Code Setup ...exe`); we
rename to `MiniMax-Code-Setup-<version>.exe` for shell-friendliness.

### 2.2 Working dir — `unpacked/`

The unpacked Windows app. **Gitignored** (1.6 GB).

After the full pipeline runs, this dir contains the **patched** artifacts:

```
unpacked/
├── $PLUGINSDIR/                                  # NSIS overhead, can rm
├── $R0/                                          # NSIS overhead, can rm
├── uninstallerIcon.ico                           # NSIS overhead, can rm
└── app-64/                                       # ← THIS is what matters
    ├── *.dll                                     # (Windows electron, irrelevant for deb)
    ├── MiniMax Inside Code.exe                   # (Windows electron, irrelevant)
    ├── locales/                                  # Chromium locales
    ├── LICENSE.electron.txt
    ├── LICENSES.chromium.html
    └── resources/
        ├── app.asar           424 MB  ← PATCHED (was 461 MB; smaller because we dropped some platform-specific files via the re-extract+repack round-trip)
        ├── app.asar.orig      461 MB  ← ORIGINAL (cp'd by build-linux-gui.sh on first run)
        ├── app.asar.unpacked/          ← Linux natives injected by build-deb.sh
        │   └── node_modules/
        │       ├── better-sqlite3/build/Release/better_sqlite3.node
        │       ├── node-pty/build/Release/pty.node
        │       ├── @nut-tree/libnut-linux/build/Release/libnut.node
        │       ├── @vscode/ripgrep-linux-x64/bin/rg
        │       └── @earendil-works/pi-tui/native/linux/  (if applicable)
        ├── elevate.exe                          # (Windows, irrelevant for deb)
        └── resources/                           # icons (.icns, .ico — see §6 known issue)
```

### 2.3 Final output — `dist/`

`build-deb.sh` writes here. **Gitignored**.

| File | Size | Purpose |
|------|------|---------|
| `dist/minimax-code_3.0.67-inside.44_amd64.deb` | ~227 MB | Main distribution. `dpkg -i` on Ubuntu. |
| `dist/minimax-code_3.0.67-inside.44_linux-x64.tar.gz` | ~337 MB | Portable (no root needed to install). |
| `dist/minimax-code_3.0.67-inside.44_linux-x64.tar` | ~1.3 GB | Includes debug symbols. |

### 2.4 Other dirs (gitignored, not committed)

| Path | Why |
|------|-----|
| `node_modules/` | any npm stuff; not used in this repo |
| `/tmp/mmx-app-v3/` | asar extract work dir (~595 MB, 44K files) |
| `/tmp/mmx-linux-install/native-builds/` | npm temp for native rebuilds |
| `/tmp/minimax-code-deb-build/` | deb packaging PKG_ROOT (1.3 GB) |
| `/tmp/asar-tool/`, `/tmp/asar3/` | @electron/asar tool installs |
| `/tmp/mmx-logs/` | runtime logs (e.g. `mmx-login-ui-*.png` capturePage debug) |
| `.test-logs/` | `tools/test-ubuntu.sh` per-version smoke logs |

---

## 3. Step-by-step procedure

### 3.1 NSIS unpack (Mac ✅, Linux ✅)

**Two-step** because the NSIS installer embeds the app payload as an inner 7z.

```bash
cd <repo>
mkdir -p inputs unpacked

# Step 1: extract outer NSIS shell
7z x 'inputs/MiniMax-Code-Setup-3.0.67-inside.44.exe' -ounpacked -y
# Produces: unpacked/$PLUGINSDIR/  (12 files, includes app-64.7z)
#           unpacked/$R0/
#           unpacked/uninstallerIcon.ico

# Step 2: extract inner app-64.7z (188 MB → 885 MB)
7z x 'unpacked/$PLUGINSDIR/app-64.7z' -ounpacked -y
# Produces 99 folders / 539 files, but LAYS THEM FLAT at unpacked/ root:
#   unpacked/MiniMax Inside Code.exe  (233 MB)
#   unpacked/resources/app.asar       (461 MB)
#   unpacked/*.dll
#   unpacked/locales/ ...

# Step 3: restructure — scripts expect unpacked/app-64/ as root
mkdir -p unpacked/app-64
for item in unpacked/*; do
  name=$(basename "$item")
  case "$name" in
    '$PLUGINSDIR'|'$R0'|'uninstallerIcon.ico') echo "[skip] $name (NSIS overhead)";;
    app-64) echo "[skip] $name (already the target)";;
    *) mv "$item" "unpacked/app-64/";;
  esac
done

# Step 4: optional cleanup of NSIS overhead
rm -rf 'unpacked/$PLUGINSDIR' 'unpacked/$R0' unpacked/uninstallerIcon.ico
```

> **Why two steps?** The NSIS installer (`Setup.exe`) is a 32-bit Windows PE
> self-extractor that contains a payload. 7z recognizes it as
> `Type=Nsis, SubType=NSIS-3 Unicode` and extracts the outer shell first.
> The actual app payload is `$PLUGINSDIR/app-64.7z` (and `app-arm64.7z` for
> ARM64, which we don't need).

> **Mac vs Linux**: identical commands. `7z 17.05+` handles NSIS-3 Unicode
> on both platforms. On macOS: `brew install p7zip`. On Ubuntu:
> `sudo apt install p7zip-full`.

### 3.2 Stage A: asar rewrite (Mac ✅, Linux ✅)

Driven by `scripts/build-linux-gui.sh` (which expects `unpacked/app-64/`
to already exist).

```bash
# Prep: install asar tool (script does this automatically, but manual is OK)
mkdir -p /tmp/asar-tool
(cd /tmp/asar-tool && npm init -y >/dev/null && npm install @electron/asar@4.3.0 --no-save)

# Run the full Stage A
ELEC43_DIR=/path/to/linux-electron-43 ./scripts/build-linux-gui.sh
```

What it does (in order):

1. **`check_deps`** — verifies `node`, `npm`, `wget`, `file`, `tar` exist and
   `$ELEC43_DIR/dist/electron` is executable. (`ELEC43_DIR` is only
   *checked* in this stage; not actually used until Stage B/C.)
2. **`install_asar_tool`** — installs `@electron/asar@4.3.0` into
   `/tmp/asar-tool/`.
3. **`ensure_unpacked`** — checks `unpacked/app-64/resources/app.asar` exists;
   if `app.asar.orig` doesn't exist, copies asar → asar.orig.
4. **`extract_asar`** — runs `asar extract` into `/tmp/mmx-app-v3/`. See
   §6 "asar 4.3.0 vs 3.2.10" for the known bug.
5. **`build_ripgrep`**, **`build_libnut`** — copy prebuilt N-API / static
   Linux binaries from npm into `/tmp/mmx-app-v3/node_modules/`. **No
   compilation**. Works on Mac (since the binaries are downloaded from
   the npm registry, not built locally).
6. **`build_better_sqlite3`**, **`build_node_pty`** — **source rebuild
   for Linux** via `@electron/rebuild`. **❌ FAILS on macOS** because
   `node-gyp` will compile for the host triple (darwin-arm64), not
   linux-x64. See §5.
7. **`patch_js`** — 6 Python heredocs that rewrite JS in
   `/tmp/mmx-app-v3/dist/main/`:
   - `dist/main/index.js` — `disableHardwareAcceleration` +
     `--disable-gpu --in-process-gpu` + `process.platform` literal patch
   - `dist/main/ipc/window.ipc.js` — robust `OPEN_EXTERNAL` handler
     (xdg-mime + .desktop Exec= parser + xdg-open + hardcoded list)
   - `dist/main/modules/tray/index.js` — skip tray on Linux
   - `dist/main/modules/deeplink/index.js` — silent protocol register
   - `dist/main/modules/local-runtime/native-sqlite-env.js` — demote
     prebuild-install-missing log to info
   - `dist/main/modules/mcode-tools/index.js` — demote integration
     unavailable log to info
   - `dist/main/windows/{loginWindow,archonChatWindow}.js` — `capturePage`
     hook for headless verification
8. **`pack_asar`** — runs `asar pack /tmp/mmx-app-v3 unpacked/app-64/resources/app.asar`.

After Stage A, the patched asar is at
`unpacked/app-64/resources/app.asar` (424 MB, down from 461 MB).
`app.asar.orig` (461 MB) is the untouched original.

### 3.3 Stage B: native rebuild (Linux only)

**This is the Mac-incompatible step.** On Linux:

```bash
# Install Electron 43 + build deps
sudo apt install -y gcc g++ make python3
mkdir -p /tmp/elec43 && (cd /tmp/elec43 && npm init -y && npm install electron@43.1.0)
export ELEC43_DIR=/tmp/elec43/node_modules/electron

# Run rebuild
cd <repo>
./scripts/build-linux-gui.sh  # stage 3 of main()
# OR (more granular):
node node_modules/.bin/electron-rebuild \
  -v 43.1.0 -e "$ELEC43_DIR" -f -w better-sqlite3,node-pty
```

**Why it fails on macOS:** `@electron/rebuild` invokes `node-gyp`, which
runs `gyp` → `make` for the **host triple** (e.g.
`arm64-apple-darwin`). It does not cross-compile. To get a
linux-x64 `.node` file, you need:
- Linux kernel + glibc (so `.so` symlinks resolve correctly)
- A matching `python3` + `gcc` for the linux-x64 target
- Or a pre-built tarball from the npm registry (which
  `better-sqlite3@12.10.1` may or may not publish for electron 43
  NMV 148; check `https://registry.npmjs.org/better-sqlite3`)

**Workarounds for Mac users:**
- **Best**: run Stage B inside `docker run --rm -v $PWD:/work -w /work
  ubuntu:24.04 bash -c "..."` (see §5.2).
- **Alternative**: skip Stage B and accept that the resulting `.deb`
  will fail to launch on Linux with `Cannot find module
  better-sqlite3` / `node-pty` errors.

### 3.4 Stage C: build .deb (Mac ✅ with `brew install dpkg`, Linux ✅)

Driven by `scripts/build-deb.sh`.

```bash
ELEC43_DIR=/path/to/linux-electron-43 ./scripts/build-deb.sh
```

What it does:

1. Dep check: `ELEC43_DIR/dist/electron` exists + `unpacked/app-64/` exists
   + **`unpacked/app-64/resources/resources/icon.png` exists** (⚠ see §6
   known issue).
2. Prepare `/tmp/minimax-code-deb-build/<pkg>_<ver>_<arch>/` as PKG_ROOT.
3. Copy `ELEC43_DIR` → `PKG_ROOT/opt/MiniMax Code/electron/`.
4. Copy `unpacked/app-64/resources/` → `PKG_ROOT/opt/MiniMax Code/app/app-64/resources/`.
5. **Inject Linux natives** from `/tmp/mmx-app-v3/node_modules/` into
   `PKG_ROOT/opt/MiniMax Code/app/app-64/resources/app.asar.unpacked/`
   (better_sqlite3.node, pty.node, libnut.node, rg, pi-tui native).
6. Build `libmmmx-shim.so` (fmod@GLIBC_2.38 fallback) and copy to
   `PKG_ROOT/opt/mmx-shared/`.
7. Generate `DEBIAN/{preinst, postinst, prerm, control, conffiles}`.
   The `preinst` runs `apt-get install -y` on a curated dep list
   + `apt-get install -f -y` as a fallback for unmet deps.
8. `dpkg-deb --build PKG_ROOT dist/...deb`.

After Stage C, `dist/minimax-code_3.0.67-inside.44_amd64.deb` exists.

### 3.5 End-to-end test (Linux only)

```bash
# Smoke test: install + launch in a clean Ubuntu 24.04 container
tools/test-ubuntu.sh 24.04

# Or manual:
docker run -it --rm \
  -v $PWD/dist:/dist:ro \
  -v /tmp/.X11-unix:/tmp/.X11-unix -e DISPLAY \
  ubuntu:24.04 bash
# (in container)
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
  libnss3 libdrm2 libnotify4 libgbm1 libxkbcommon0 xdg-utils xvfb
dpkg -i /dist/minimax-code_3.0.67-inside.44_amd64.deb
Xvfb :99 -screen 0 1280x800x24 &
DISPLAY=:99 /opt/MiniMax\ Code/run.sh
# Look for "[LocalRuntimeUtility] runtime started" in main.log
```

Expected log markers (success):
```
[info]  [LocalRuntime] Launch plan: buildEnv=prod
[info]  [LocalRuntimeUtility] runtime started
[info]  [WindowManager] Registered window: type=login, id=1
```

---

## 4. Environment setup (side-by-side)

### 4.1 macOS (Apple Silicon or Intel)

```bash
# Build tools
brew install p7zip dpkg

# Node toolchain (we use nvm in this project)
# nvm install 22  (or use existing 22.x)
# Ensure node 22+ and npm 10+

# Docker (for Stage B + runtime test)
brew install --cask docker          # or download Docker Desktop
docker pull ubuntu:24.04
```

**Notes**:
- `dpkg` from Homebrew can `dpkg-deb --build` but **cannot**
  `dpkg -i` ("This installation of dpkg is not configured to install
  software"). Fine for our build purpose; we don't install on the
  build host.
- `p7zip` 17.05 is the minimum for full NSIS-3 Unicode support.
- The script's hardcoded `http_proxy=http://127.0.0.1:20172/` in
  `build-linux-gui.sh:54` is **only needed behind a corporate proxy**.
  Override or unset on a direct network.

### 4.2 Ubuntu 24.04 (or any modern Debian/Ubuntu)

```bash
# Build tools
sudo apt update
sudo apt install -y p7zip-full dpkg dpkg-dev gcc g++ make python3 \
  libnss3 libdrm2 libnotify4 libgbm1 libxkbcommon0 xdg-utils

# Node toolchain
# (use nvm or distro node — script needs node 22+)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
nvm install 22

# Electron 43 (needed for ELEC43_DIR)
mkdir -p /tmp/elec43 && (cd /tmp/elec43 && npm init -y && npm install electron@43.1.0)
export ELEC43_DIR=/tmp/elec43/node_modules/electron
```

### 4.3 What's in common vs different

| Item | macOS | Ubuntu | Why it matters |
|------|-------|--------|----------------|
| `7z` / `7za` | `brew install p7zip` | `apt install p7zip-full` | NSIS unpack |
| `dpkg-deb` | `brew install dpkg` | `apt install dpkg-dev` | deb packaging |
| `gcc` / `g++` / `make` | Xcode CLT (or `brew install gcc make`) | `apt install build-essential` | native rebuild |
| `python3` | preinstalled or `brew install python` | `apt install python3` | JS patch scripts |
| `node` 22+ | via nvm | via nvm | npm + electron-rebuild |
| Electron 43 binary | **downloaded for Mac** (won't run on Mac, used as artifact) | **downloaded for Linux** (used for build) | ELEC43_DIR |
| Docker | Docker Desktop | `apt install docker.io` (or docker-ce) | Cross-version smoke test |
| `LD_PRELOAD` shim build | `src/build-shim.sh` (Mac: builds .dylib, irrelevant) | `src/build-shim.sh` (Linux: builds .so) | GLIBC fallback |

---

## 5. Mac-specific: what works, what doesn't

### 5.1 What works on macOS

| Stage | Tool | Status |
|-------|------|--------|
| §3.1 NSIS unpack | `7z x` (twice) + `mv` | ✅ Same commands as Linux |
| §3.2 `check_deps` | `command -v` + file exists | ✅ |
| §3.2 `install_asar_tool` | `npm install @electron/asar` | ✅ |
| §3.2 `ensure_unpacked` | file exists check | ✅ |
| §3.2 `extract_asar` | `asar extract` | ✅ (with known bug, see §6) |
| §3.2 `build_ripgrep` | `npm install @vscode/ripgrep` + cp | ✅ (downloads linux-x64 binary) |
| §3.2 `build_libnut` | `npm install @nut-tree-fork/libnut` + cp | ✅ (N-API, ABI-stable) |
| §3.2 `patch_js` | Python text manipulation | ✅ |
| §3.2 `pack_asar` | `asar pack` | ✅ |
| §3.4 `build-deb.sh` dep check | file exists | ✅ (with caveats) |
| §3.4 `dpkg-deb --build` | `brew install dpkg` | ✅ (produces valid .deb) |

### 5.2 What does NOT work on macOS

| Stage | Why | Workaround |
|-------|-----|------------|
| `build_better_sqlite3` | `node-gyp` compiles for host triple (darwin-arm64), not linux-x64 | Run in Linux container; see §5.3 |
| `build_node_pty` | Same | Same |
| Stage B output validation | Mac .node file won't load on Linux | Same |
| Stage C `cp $ELEC43_SRC` | `$ELEC43_DIR/dist/electron` is a Linux ELF binary; `cp -r` works but the binary won't run on Mac | Acceptable — deb only runs on Linux |
| `dpkg -i` the resulting .deb | `brew install dpkg` warns "not configured to install software" | Use Linux container / VM / real Ubuntu box |
| `tools/test-ubuntu.sh` | Pulls `ubuntu:24.04` container; needs Docker Desktop running on Mac | ✅ Works **with Docker Desktop** |

### 5.3 Recommended workflow on macOS

For a full end-to-end build + test:

```bash
# === ONCE: prepare a Linux build env in Docker ===
docker run -it --rm \
  -v $PWD:/work -w /work \
  -v /tmp/elec43:/tmp/elec43 \
  ubuntu:24.04 bash

# (inside container)
apt update && apt install -y p7zip-full dpkg-dev gcc g++ make python3 \
  libnss3 libdrm2 libnotify4 libgbm1 libxkbcommon0 xdg-utils
cd /work
# Stage A: NSIS unpack + asar extract + JS patch
# (do this on Mac, or in container — pure Node/Python)
7z x 'inputs/MiniMax-Code-Setup-3.0.67-inside.44.exe' -ounpacked
7z x 'unpacked/$PLUGINSDIR/app-64.7z' -ounpacked
# ... restructure into unpacked/app-64/ ...

# Stage B + C: native rebuild + deb (must be in container)
(cd /tmp/elec43 && npm init -y && npm install electron@43.1.0)
export ELEC43_DIR=/tmp/elec43/node_modules/electron
ELEC43_DIR=$ELEC43_DIR ./scripts/build-linux-gui.sh   # does A + B
ELEC43_DIR=$ELEC43_DIR ./scripts/build-deb.sh         # does C
ls -lh dist/
```

**Or simpler**: run `tools/test-ubuntu.sh 24.04` after Stage C. It pulls
a fresh container, installs the .deb, and runs the smoke test.

---

## 6. Known issues & gotchas

### 6.1 `asar 4.3.0` vs `3.2.10` extract bug

Both versions **succeed** at extracting 44,582 files from
`app.asar`, but both **error at the end** with messages like:

```
Error: ENOENT: no such file or directory, open
  '.../app.asar.unpacked/node_modules/@earendil-works/pi-tui/native/darwin/prebuilds/darwin-arm64/darwin-modifiers.node'
```

This is because the asar header references files in `asar.unpacked/`
that don't exist on this machine (the Windows installer only ships
Windows prebuilds for `pi-tui`, not macOS or Linux).

**Impact on the pipeline**: **none** for the JS patch step (the missing
files are `.node` binaries that we replace anyway in Stage B/C). The
exit code is non-zero, so scripts using `set -e` will abort; wrap in
`|| true` or check for "ENOENT" in the error.

**Fix idea** (P1 in `AGENTS.md`): write a Python asar parser
(`tools/extract_asar.py`) that ignores missing-asar-unpacked entries.

### 6.2 `build-deb.sh:32` references nonexistent `icon.png`

```bash
ICON_PNG_SRC="$PROJECT_ROOT/unpacked/app-64/resources/resources/icon.png"
```

But the Windows NSIS installer only ships `icon.icns` (macOS) and
`icon.ico` (Windows) — **no `icon.png`**. The check
`if [ ! -f "$ICON_PNG_SRC" ]` will fail.

**Workaround**: convert `icon.ico` → `icon.png` once after unpack:
```bash
# On Mac: brew install imagemagick
convert 'unpacked/app-64/resources/resources/icon.ico[0]' \
        unpacked/app-64/resources/resources/icon.png
# Or use a single-frame .icns:
# brew install icnsutils
# pngpaste ... (more complex; .ico conversion is simpler)
```

**Fix idea** (P2 in `AGENTS.md`): make `build-deb.sh` fall back to
`.ico` or generate a PNG from the `.icns` at build time.

### 6.3 Hardcoded paths in `build-linux-gui.sh:42-54`

```bash
ELEC43_DIR="${ELEC43_DIR:-/home/weekbin/Works/repositories/orca/node_modules/.pnpm/electron@43.1.0/node_modules/electron}"
# ...
export http_proxy="${http_proxy:-http://127.0.0.1:20172/}"
export https_proxy="${https_proxy:-http://127.0.0.1:20172/}"
```

The fallback `ELEC43_DIR` points to the original author's machine.
**Always override** with `ELEC43_DIR=...` env var.

The proxy defaults only matter behind a corporate proxy. **Unset on
direct networks** (`unset http_proxy https_proxy`) to avoid hangs.

### 6.4 `find | xargs touch -d` slowness in `build-deb.sh`

`dpkg-deb` step 11/12 does `find ... | xargs touch -d` on the 1.3 GB
PKG_ROOT to normalize mtimes. Takes 5+ minutes. Workaround: comment
out, or just wait. `dpkg-deb --build` itself takes another 5-10
minutes at 1500% CPU (zstd multithreaded compression).

### 6.5 GLIBC compatibility (P0 in `AGENTS.md`)

`better-sqlite3` rebuilt on Ubuntu 24.04 (GLIBC 2.39) references
`fmod@GLIBC_2.38`. On 22.04 (2.35) / 20.04 (2.31), the system
`libm.so.6` lacks this versioned symbol.

**Current mitigation**: `src/libmmmx-shim.c` exports `fmod@GLIBC_2.38`
+ `fmod@GLIBC_2.2.5`; `src/better-sqlite3-binding.gyp.patch` adds
`-L/opt/mmx-shared -lmmmx` to better-sqlite3 link flags.

**Status**: shim is built and deployed to `/opt/mmx-shared/libmmmx.so`
in the .deb. **End-to-end verification on Ubuntu 22.04 has not been
run yet** — see `AGENTS.md §6 P0` for the 5 candidate solutions (the
cleanest being option D: swap to `node-sqlite3-wasm`).

### 6.6 Idempotency: index.js patch

`build-linux-gui.sh`'s `patch_js` for `dist/main/index.js` checks:

```python
if "[mmx-patch] disableHardwareAcceleration" not in s:
    s = s.replace(...)
```

But the inserted text contains `mmx-patch: Wine/Electron GPU compat`
(comment) and `disableHardwareAcceleration()` (code) — **not** the
literal substring `[mmx-patch] disableHardwareAcceleration`. So the
check is always True and the replace runs every time, doubling the
patch on second run.

**Workaround**: only run `build-linux-gui.sh` once per unpacked
session, or use `git diff` to detect if a re-patch happened.

**Fix idea**: change the check to a marker that actually appears in
the inserted text (e.g. `// === mmx-patch: Wine/Electron GPU compat ===`).

---

## 7. Re-running the pipeline (idempotency)

| State | What happens on re-run |
|-------|-------------------------|
| `inputs/MiniMax-Code-Setup-*.exe` deleted, `unpacked/` present | Re-extract from the existing `unpacked/app-64/resources/app.asar.orig` |
| `unpacked/app-64/resources/app.asar.orig` missing, `app.asar` present | `ensure_unpacked` copies `app.asar` → `app.asar.orig` (re-baseline) |
| `app.asar.orig` present, `app.asar` patched | `extract_asar` reads from `.orig` (not the patched one) |
| `/tmp/mmx-app-v3` from a previous run | `extract_asar` does `rm -rf` first |
| `/tmp/mmx-linux-install/native-builds/` from a previous run | `build_better_sqlite3` reuses if `better_sqlite3.node` exists |
| `dist/*.deb` from a previous run | Overwritten by `build-deb.sh` |

**Clean re-run** (start from scratch):
```bash
rm -rf unpacked/ /tmp/mmx-app-v3 /tmp/minimax-code-deb-build
./scripts/build-linux-gui.sh && ./scripts/build-deb.sh
```

---

## 8. End-to-end verification (Linux only)

```bash
# Single-version smoke (e.g. noble)
tools/test-ubuntu.sh 24.04

# All supported versions
tools/test-ubuntu.sh

# Custom deb
DEB_PATH=/path/to/deb tools/test-ubuntu.sh 24.04
```

`test-ubuntu.sh` does, per version:
1. `docker run -it --rm ubuntu:24.04 ...`
2. Install runtime deps (libnss3, libgbm1, etc.)
3. `dpkg -i` the .deb
4. Start Xvfb + the app
5. Wait for the "LocalRuntimeUtility runtime started" log marker
6. Compare to `EXPECTED[version]` map:
   - 20.04 → `FAIL` (GLIBC too old)
   - 22.04 → `PARTIAL` (shim link unverified)
   - 24.04+ → `PASS`

Exit 0 = all versions match expected. Exit 1 = unexpected outcome
(usually a new bug). Logs go to `.test-logs/<codename>.log`.

---

## 9. Quick reference: file → purpose

| Path | Purpose |
|------|---------|
| `inputs/MiniMax-Code-Setup-3.0.67-inside.44.exe` | The Windows NSIS installer (gitignored) |
| `unpacked/app-64/` | After NSIS unpack (gitignored) |
| `unpacked/app-64/resources/app.asar` | Patched asar (424 MB) |
| `unpacked/app-64/resources/app.asar.orig` | Original asar (461 MB, immutable) |
| `unpacked/app-64/resources/app.asar.unpacked/` | Where Linux natives get injected |
| `/tmp/mmx-app-v3/` | asar extract work dir (gitignored) |
| `/tmp/mmx-app-v3/node_modules/better-sqlite3/build/Release/better_sqlite3.node` | Linux-x64 binding (from Stage B) |
| `/tmp/asar-tool/` | @electron/asar 4.3.0 install (gitignored) |
| `dist/minimax-code_3.0.67-inside.44_amd64.deb` | Final deb output (gitignored) |
| `scripts/build-linux-gui.sh` | Stage A + B driver |
| `scripts/build-deb.sh` | Stage C driver |
| `scripts/build-targz.sh` | Optional tar.gz packaging |
| `scripts/build-all.sh` | Runs all 3 above |
| `scripts/install-protocol-handler.sh` | Registers `minimax-cn://` OAuth callback |
| `scripts/run-mmx-linux.sh` | `LD_PRELOAD` wrapper to launch the app |
| `src/libmmmx-shim.c` | fmod@GLIBC_2.38 fallback (for jammy/focal) |
| `src/better-sqlite3-binding.gyp.patch` | Adds `-lmmmx` to better-sqlite3 link |
| `tools/test-ubuntu.sh` | Cross-version smoke test |
| `README.md` | User-facing TL;DR |
| `AGENTS.md` | AI-agent-focused architecture/troubleshooting |
| `docs/PIPELINE.md` | This file — full end-to-end record |
