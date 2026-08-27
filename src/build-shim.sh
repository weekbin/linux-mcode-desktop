#!/usr/bin/env bash
# Build libmmmx.so shim for old-GLIBC fmod resolution
set -e
cd "$(dirname "$0")"
gcc -shared -fPIC -nostdlib -o libmmmx.so libmmmx-shim.c \
    -Wl,--version-script=libmmmx-shim.map
echo "✓ Built libmmmx.so"
nm -D libmmmx.so | grep fmod
