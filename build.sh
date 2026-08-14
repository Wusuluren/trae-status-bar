#!/bin/bash
# trae-status-bar 构建脚本
#
# 背景：本机 CommandLineTools 的 swiftc 是 swiftlang-5.7.1.135.3，
# 而 SDK 里的 .swiftinterface 由 5.7.1.134.4 构建，编译器会报
# "this SDK is not supported by the compiler"，直接 swiftc 编译失败。
# 解决：在 .build/sdkovl 下做一个 SDK 覆盖层（其余部分符号链接到真实 SDK，
# 仅真实拷贝 usr/lib/swift 并把接口版本号 134.4 改为 135.3），再用 -sdk 指向它。
# 若机器上编译器与 SDK 版本匹配，则直接走普通编译。
set -euo pipefail
cd "$(dirname "$0")"

REAL=/Library/Developer/CommandLineTools/SDKs/MacOSX13.0.sdk
OVL=.build/sdkovl/MacOSX13.0.sdk
CLANGMOD=.build/clangmod

build_plain() {
  swiftc -o trae-status-bar Sources/trae-status-bar/main.swift -framework AppKit
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
    -o trae-status-bar Sources/trae-status-bar/main.swift -framework AppKit
}

if build_plain 2>/tmp/tsb_build_err.log; then
  echo "=== BUILD OK ==="
else
  if grep -q "not supported by the compiler" /tmp/tsb_build_err.log; then
    echo "==> 编译器与 SDK 版本不匹配，改用 SDK 覆盖层构建"
    build_overlay
    echo "=== BUILD OK (overlay) ==="
  else
    cat /tmp/tsb_build_err.log
    exit 1
  fi
fi
