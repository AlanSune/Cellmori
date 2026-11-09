#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
mkdir -p "$ROOT/.build/module-cache"
xcrun swiftc -O -module-cache-path "$ROOT/.build/module-cache" -framework AppKit -framework SwiftUI \
  "$ROOT/Source/MenuPanelNavigation.swift" "$ROOT/Tests/MenuPanelNavigationTests.swift" -o "$ROOT/.build/menu-navigation-tests"
"$ROOT/.build/menu-navigation-tests"
