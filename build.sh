#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
work="$(mktemp -d)"
trap 'rmdir "$work" 2>/dev/null || true' EXIT
out="$PWD/dist"
app="$out/Mihomo Byte Log.app"
mkdir -p "$app/Contents/MacOS"

for arch in arm64 x86_64; do
    xcrun clang -target "$arch-apple-macos13.0" -O2 -Wall -Wextra -c LocalSocket.c -o "$work/$arch.o"
    xcrun swiftc -target "$arch-apple-macos13.0" -O -import-objc-header LocalSocket.h \
        Traffic.swift App.swift "$work/$arch.o" -lcurl -lsqlite3 -o "$work/monitor-$arch"
done
xcrun lipo -create "$work/monitor-arm64" "$work/monitor-x86_64" -output "$app/Contents/MacOS/ClashTraffic"
unlink "$work/arm64.o"
unlink "$work/x86_64.o"
unlink "$work/monitor-arm64"
unlink "$work/monitor-x86_64"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto -c -k --keepParent "$app" "$out/Mihomo-Byte-Log-macOS.zip"
