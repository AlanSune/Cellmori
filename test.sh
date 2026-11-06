#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
mkdir -p "$ROOT/.build/module-cache"
xcrun swiftc -O -module-cache-path "$ROOT/.build/module-cache" -framework IOKit -framework SystemConfiguration \
  "$ROOT/Source/Shared.swift" "$ROOT/Source/ControlChannel.swift" "$ROOT/Source/ServiceStatus.swift" "$ROOT/Source/PolicyTests.swift" \
  -o "$ROOT/.build/policy-tests"
"$ROOT/.build/policy-tests"
