#!/bin/bash
# qoder-status-bar 构建脚本（qoder ide 版本）
#
# 与上层 trae-status-bar/build.sh 同源：本机 CommandLineTools 的 swiftc 与 SDK 版本
# 不匹配时会报 "this SDK is not supported by the compiler"，故在 .build/sdkovl 下做
# SDK 覆盖层（仅真实拷贝 usr/lib/swift 并把接口版本号 134.4 改为 135.3）再编译。
# 环境匹配则走普通编译。
set -euo pipefail
cd "$(dirname "$0")"

REAL=/Library/Developer/CommandLineTools/SDKs/MacOSX13.0.sdk
OVL=.build/sdkovl/MacOSX13.0.sdk
CLANGMOD=.build/clangmod
SRCS=$(find Sources/qoder-status-bar -name "*.swift" | sort)

build_plain() {
  # -parse-as-library 由 main.swift 顶层入口自动处理；多文件同编译为单模块
  swiftc -o qoder-status-bar $SRCS -framework AppKit
}

build_overlay() {
  if [ ! -f "$OVL/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface" ] \
     || ! grep -q "5.7.1.135.3" "$OVL/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"; then
    echo "==> 构建 SDK 覆盖层 ($OVL) ..."
    rm -rf "$OVL"; mkdir -p "$OVL"
    for e in $(ls "$REAL"); do [ "$e" = "usr" ] || ln -s "$REAL/$e" "$OVL/$e"; done
    mkdir -p "$OVL/usr"
    for e in $(ls "$REAL/usr"); do [ "$e" = "lib" ] || ln -s "$REAL/usr/$e" "$OVL/usr/$e"; done
    mkdir -p "$OVL/usr/lib"
    for e in $(ls "$REAL/usr/lib"); do [ "$e" = "swift" ] || ln -s "$REAL/usr/lib/$e" "$OVL/usr/lib/$e"; done
    cp -R "$REAL/usr/lib/swift" "$OVL/usr/lib/swift"
    find "$OVL/usr/lib/swift" -name "*.swiftinterface" -exec sed -i '' 's/5\.7\.1\.134\.4/5.7.1.135.3/g' {} +
  fi
  mkdir -p "$CLANGMOD"
  swiftc -sdk "$OVL" -Xcc -fmodules-cache-path="$CLANGMOD" \
    -o qoder-status-bar $SRCS -framework AppKit
}

if build_plain 2>/tmp/qsb_build_err.log; then
  echo "=== BUILD OK ==="
else
  if grep -q "not supported by the compiler" /tmp/qsb_build_err.log; then
    echo "==> 编译器与 SDK 版本不匹配，改用 SDK 覆盖层构建"
    build_overlay
    echo "=== BUILD OK (overlay) ==="
  else
    cat /tmp/qsb_build_err.log
    exit 1
  fi
fi
