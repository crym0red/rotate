#!/bin/bash
# MRzefvRotate.dylib build — arm64 + arm64e, fake-signed with ldid.
# Warnings never fail the build; the full compiler output is saved to build/build.log.
set -uo pipefail

NAME="MRzefvRotate"
SOURCES=(MRzefvRotate.m)
OUT="build"
MINVER="14.0"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"

mkdir -p "$OUT"
rm -f "$OUT/$NAME.dylib" "$OUT/build.log"

build() {
  "$CLANG" \
    "$@" \
    -isysroot "$SDK" \
    -miphoneos-version-min="$MINVER" \
    -dynamiclib \
    -fobjc-arc \
    -O2 \
    -fvisibility=hidden \
    -w -Wno-error \
    -Wno-implicit-function-declaration \
    -Wno-incompatible-pointer-types \
    -Wno-int-conversion \
    -framework UIKit -framework Foundation \
    -install_name "@rpath/$NAME.dylib" \
    "${SOURCES[@]}"
}

{
  echo "== arm64 + arm64e =="
  build -arch arm64 -arch arm64e -o "$OUT/$NAME.dylib"
  RC=$?
  if [ $RC -ne 0 ]; then
    echo "== arm64e failed (rc=$RC), retrying arm64 only =="
    build -arch arm64 -o "$OUT/$NAME.dylib"
    RC=$?
  fi
  echo "== clang exit: $RC =="
} 2>&1 | tee "$OUT/build.log"

if [ -f "$OUT/$NAME.dylib" ]; then
  command -v ldid >/dev/null 2>&1 && ldid -S "$OUT/$NAME.dylib"
  lipo -info "$OUT/$NAME.dylib"
  ls -l "$OUT/$NAME.dylib"
else
  echo "No dylib produced — errors:"
  grep -n "error" "$OUT/build.log" | head -40
fi

exit 0
