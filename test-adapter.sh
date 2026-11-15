#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
mkdir -p "$ROOT/.build"
xcrun clang -Wall -Wextra -Werror -O2 -framework IOKit -framework CoreFoundation \
 "$ROOT/Tests/AdapterControlTests.c" -o "$ROOT/.build/adapter-control-tests"
"$ROOT/.build/adapter-control-tests"
