#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
mkdir -p "$ROOT/.build/module-cache"
xcrun swiftc -O -module-cache-path "$ROOT/.build/module-cache" -framework IOKit \
 "$ROOT/Source/Shared.swift" "$ROOT/Source/SleepControl.swift" "$ROOT/Tests/SleepControlTests.swift" \
 -o "$ROOT/.build/sleep-control-tests"
"$ROOT/.build/sleep-control-tests"
