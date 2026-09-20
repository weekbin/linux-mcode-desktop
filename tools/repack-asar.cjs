#!/usr/bin/env node
// repack-asar.cjs — 保留原 asar unpacked markers 的 repack 工具
//
// 上游 build-linux-gui.sh 用 `asar pack` (无 --unpack) repack, 会把原版
// asar 里几百个 unpacked markers (jszip/pi-tui/better-sqlite3/node-pty/libnut...)
// 全部丢掉 → 运行时 asar.unpacked 下的 native/资源文件找不到。
// 这个工具从 app.asar.orig 读出全部 unpacked 条目, repack 时原样保留,
// 并把我们注入的 Linux native .node 一并标成 unpacked。
//
// 用法: node tools/repack-asar.cjs <SRC_DIR> <OUT_ASAR> <ORIG_ASAR>
//   SRC_DIR   extract 出来的 asar 内容目录 (e.g. /tmp/mmx-app-v3)
//   OUT_ASAR  输出路径 (e.g. unpacked/app-64/resources/app.asar)
//   ORIG_ASAR 原版 asar 备份 (app.asar.orig), 用于读取 unpacked markers
//
// @electron/asar 模块解析顺序: $ASAR_NODE_MODULES → /tmp/asar-tool/node_modules
// → <repo>/node_modules (由 scripts/build-linux-gui.sh 的 install_asar_tool 装)

const fs = require('fs');
const path = require('path');

const SRC = process.argv[2];
const OUT = process.argv[3];
const ORIG = process.argv[4];
if (!SRC || !OUT || !ORIG) {
  console.error('usage: repack-asar.cjs <SRC_DIR> <OUT_ASAR> <ORIG_ASAR>');
  process.exit(1);
}

const candidates = [
  process.env.ASAR_NODE_MODULES,
  '/tmp/asar-tool/node_modules',
  path.join(__dirname, '..', 'node_modules'),
].filter(Boolean);

let asarDir = null;
for (const c of candidates) {
  try {
    require.resolve('@electron/asar', { paths: [c] });
    asarDir = c;
    break;
  } catch {}
}
if (!asarDir) {
  console.error(`[error] 找不到 @electron/asar, 试过: ${candidates.join(', ')}`);
  console.error('        先跑 scripts/build-linux-gui.sh (会自动装) 或 npm install @electron/asar');
  process.exit(1);
}

const mainEntry = require.resolve('@electron/asar', { paths: [asarDir] });
// exports 字段不暴露 ./lib/* 子路径, 从主入口推包目录再按绝对路径 require
const asarPkgDir = path.dirname(path.dirname(mainEntry));
const { Filesystem } = require(path.join(asarPkgDir, 'lib', 'filesystem.js'));
const { crawl } = require(path.join(asarPkgDir, 'lib', 'crawlfs.js'));
const asar = require(path.join(asarPkgDir, 'lib', 'asar.js'));
const { writeFilesystem } = require(path.join(asarPkgDir, 'lib', 'disk.js'));

// 从 orig asar 提取所有 unpacked 路径（文件 + 目录）
const headerObj = asar.getRawHeader(ORIG).header;
const origUnpPaths = new Set();

function walk(node, prefix = '') {
  for (const [k, v] of Object.entries(node)) {
    const p = prefix + '/' + k;
    if (v && typeof v === 'object') {
      if (v.unpacked === true) {
        // 不管是 file 还是 dir, 都存 - file 用作 unpack match, dir 用作 ancestor
        origUnpPaths.add(p);
      }
      if (v.files) walk(v.files, p);
    }
  }
}
walk(headerObj.files || {});
console.log(`Orig unpacked entries: ${origUnpPaths.size}`);

// 也额外加: 注入的 Linux native (.node binary files in app.asar.unpacked)
const extraNative = [
  'node_modules/better-sqlite3/build/Release/better_sqlite3.node',
  'node_modules/node-pty/build/Release/pty.node',
  'node_modules/@nut-tree/libnut-linux/build/Release/libnut.node',
];
for (const p of extraNative) {
  origUnpPaths.add('/' + p);
  // ancestor dirs
  const parts = p.split('/');
  for (let i = 1; i < parts.length; i++) {
    origUnpPaths.add('/' + parts.slice(0, i).join('/'));
  }
}

const checkUnpack = (relPath) => origUnpPaths.has('/' + relPath);

(async () => {
  const [filenames, metadata] = await crawl(SRC + '/**/*', { dot: true });
  console.log(`Files: ${filenames.length}`);

  const filesystem = new Filesystem(SRC);
  const files = [];
  const links = [];

  const filenamesSorted = filenames.slice().sort();

  for (const filename of filenamesSorted) {
    const meta = metadata[filename];
    const rel = path.relative(SRC, filename);
    const shouldUnpack = checkUnpack(rel);

    switch (meta.type) {
      case 'directory':
        filesystem.insertDirectory(filename, shouldUnpack);
        break;
      case 'file':
        const dup = await filesystem.insertFile(filename, () => fs.createReadStream(filename), shouldUnpack, meta, {});
        files.push({ filename, unpack: shouldUnpack, duplicate: dup });
        break;
      case 'link':
        filesystem.insertLink(filename, shouldUnpack);
        links.push({ filename, unpack: shouldUnpack });
        break;
    }
  }

  await fs.promises.mkdir(path.dirname(OUT), { recursive: true });
  await writeFilesystem(OUT, filesystem, { files, links }, metadata);

  const sz = (fs.statSync(OUT).size / 1024 / 1024).toFixed(0);
  const unpackedCount = files.filter(f => f.unpack).length;
  console.log(`✓ Repacked ${sz}M with ${unpackedCount} unpacked files`);
})();
