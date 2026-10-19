#!/bin/bash
# MRzefvRotate.dylib build — arm64 + arm64e, unsigned-friendly (ldid fake-sign)
set -euo pipefail

NAME="MRzefvRotate"
SOURCES=(MRzefvRotate.m)
OUT="build"
MINVER="14.0"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"

mkdir -p "$OUT"
rm -f "$OUT/$NAME.dylib"

"$CLANG" \
  -arch arm64 -arch arm64e \
  -isysroot "$SDK" \
  -miphoneos-version-min="$MINVER" \
  -dynamiclib \
  -fobjc-arc \
  -O2 \
  -fvisibility=hidden \
  -framework UIKit -framework Foundation \
  -install_name "@rpath/$NAME.dylib" \
  "${SOURCES[@]}" \
  -o "$OUT/$NAME.dylib"

if command -v ldid >/dev/null 2>&1; then
  ldid -S "$OUT/$NAME.dylib"
fi

lipo -info "$OUT/$NAME.dylib"
ls -l "$OUT/$NAME.dylib"
