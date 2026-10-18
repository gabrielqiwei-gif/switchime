#!/bin/bash
# 编译并打包 SwitchIME.app（arm64 + x86_64 通用二进制）
set -euo pipefail
cd "$(dirname "$0")"

APP="SwitchIME.app"
BIN="$APP/Contents/MacOS/SwitchIME"
MIN_MACOS="12.0"

# 把临时目录和模块缓存放到工程内（某些环境下系统默认路径不可写）
export TMPDIR="$PWD/.build/tmp"
mkdir -p "$TMPDIR" "$PWD/.build/mc" "$PWD/.build/obj"

SOURCES=(Sources/main.swift Sources/InputSources.swift)
FLAGS=(-O -swift-version 5 -module-cache-path "$PWD/.build/mc" -framework Cocoa -framework Carbon)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 arm64"
swiftc "${FLAGS[@]}" -target "arm64-apple-macosx$MIN_MACOS" \
       "${SOURCES[@]}" -o .build/obj/SwitchIME-arm64

echo "==> 编译 x86_64"
if swiftc "${FLAGS[@]}" -target "x86_64-apple-macosx$MIN_MACOS" \
          "${SOURCES[@]}" -o .build/obj/SwitchIME-x86_64 2>/dev/null; then
    lipo -create -output "$BIN" .build/obj/SwitchIME-arm64 .build/obj/SwitchIME-x86_64
    echo "    通用二进制：$(lipo -archs "$BIN")"
else
    cp .build/obj/SwitchIME-arm64 "$BIN"
    echo "    ⚠️ x86_64 编译失败，仅打包 arm64 版本"
fi

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/*.icns "$APP/Contents/Resources/"

# 本地化资源（en.lproj / zh-Hans.lproj）
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done

echo "==> 签名（ad-hoc）"
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || echo "    ad-hoc 签名失败，不影响本机运行"

echo "==> 完成：$PWD/$APP"
