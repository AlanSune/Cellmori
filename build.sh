#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
APP="$ROOT/Cellmori.app"
BUILD="$ROOT/.build"
mkdir -p "$BUILD/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun clang -O2 -Wall -Wextra -c "$ROOT/Source/SMC.c" -o "$BUILD/SMC.o"
FLAGS=(-O -module-cache-path "$BUILD/module-cache" -import-objc-header "$ROOT/Source/SMC.h" -framework IOKit -framework Foundation -framework SystemConfiguration)
xcrun swiftc "${FLAGS[@]}" "$ROOT/Source/Shared.swift" "$ROOT/Source/ControlChannel.swift" "$ROOT/Source/Helper.swift" "$BUILD/SMC.o" -o "$APP/Contents/Resources/cellmori-helper"
xcrun swiftc "${FLAGS[@]}" -framework SwiftUI -framework AppKit -framework Charts -framework ServiceManagement "$ROOT/Source/Shared.swift" "$ROOT/Source/ControlChannel.swift" "$ROOT/Source/ServiceStatus.swift" "$ROOT/Source/MenuBarIcon.swift" "$ROOT/Source/App.swift" "$BUILD/SMC.o" -o "$APP/Contents/MacOS/Cellmori"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/Source/install.sh" "$ROOT/Source/uninstall.sh" "$APP/Contents/Resources/"
xcrun swiftc -O -module-cache-path "$BUILD/module-cache" "$ROOT/Source/MakeIcon.swift" -o "$BUILD/make-icon"
"$BUILD/make-icon" "$BUILD/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Cellmori</string>
<key>CFBundleDisplayName</key><string>Cellmori 电池管家</string>
<key>CFBundleIdentifier</key><string>io.cellmori.app</string>
<key>CFBundleVersion</key><string>16</string>
<key>CFBundleShortVersionString</key><string>0.6.0</string>
<key>CFBundleExecutable</key><string>Cellmori</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --options runtime --sign - "$APP/Contents/Resources/cellmori-helper"
codesign --force --options runtime --sign - "$APP"
echo "Built: $APP"
