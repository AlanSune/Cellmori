#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
BUILD="$ROOT/.build"
mkdir -p "$BUILD/module-cache"
xcrun clang -O2 -c "$ROOT/Source/SMC.c" -o "$BUILD/SMC.o"
xcrun swiftc -D SCREENSHOT_EXPORT -O -module-cache-path "$BUILD/module-cache" \
  -import-objc-header "$ROOT/Source/SMC.h" -framework IOKit -framework Foundation -framework SystemConfiguration \
  -framework SwiftUI -framework AppKit -framework Charts -framework ServiceManagement \
  "$ROOT/Source/Shared.swift" "$ROOT/Source/ControlChannel.swift" "$ROOT/Source/ServiceStatus.swift" \
  "$ROOT/Source/MenuBarIcon.swift" "$ROOT/Source/MenuPanelNavigation.swift" "$ROOT/Source/UpdateService.swift" "$ROOT/Source/AppUpdater.swift" "$ROOT/Source/App.swift" \
  "$ROOT/Tools/ExportScreenshots.swift" "$BUILD/SMC.o" -o "$BUILD/export-screenshots"
"$BUILD/export-screenshots" "$ROOT/docs/images"
