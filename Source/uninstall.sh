#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
[[ $EUID -eq 0 ]] || { echo '请使用 sudo bash uninstall.sh'; exit 1; }
HELPER='/Library/PrivilegedHelperTools/io.cellmori.helper'
if [[ -e "$HELPER" ]]; then
  [[ ! -L "$HELPER" && "$(stat -f '%u' "$HELPER")" = 0 ]] || { echo '服务权限异常，停止卸载'; exit 1; }
  mode=$(stat -f '%Lp' "$HELPER")
  (( (8#$mode & 8#022) == 0 )) || { echo '服务权限异常，停止卸载'; exit 1; }
  "$HELPER" reset
fi
launchctl bootout system/io.cellmori.helper 2>/dev/null || true
rm -f '/Library/LaunchDaemons/io.cellmori.helper.plist' "$HELPER"
# Keep a strict list; do not recursively delete a directory as root.
rm -f '/Library/Application Support/Cellmori/client-identity.plist' '/Library/Application Support/Cellmori/state.json' '/Library/Application Support/Cellmori/configuration.json' '/Library/Application Support/Cellmori/firmware-access.json' '/Library/Application Support/Cellmori/lock'
rmdir '/Library/Application Support/Cellmori' 2>/dev/null || true
echo '已恢复正常充电并移除后台服务。应用及个人历史记录可自行删除。'
