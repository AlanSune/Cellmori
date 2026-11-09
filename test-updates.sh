#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
mkdir -p "$ROOT/.build/module-cache"
xcrun swiftc -O -module-cache-path "$ROOT/.build/module-cache" -framework IOKit -framework AppKit -framework SwiftUI \
  "$ROOT/Source/Shared.swift" "$ROOT/Source/UpdateService.swift" "$ROOT/Source/AppUpdater.swift" "$ROOT/Tests/UpdateServiceTests.swift" \
  -o "$ROOT/.build/update-tests"
"$ROOT/.build/update-tests"
