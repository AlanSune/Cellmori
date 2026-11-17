#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
[[ $EUID -eq 0 ]] || { echo '需要管理员权限'; exit 1; }
SOURCE_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
HELPER='/Library/PrivilegedHelperTools/io.cellmori.helper'
DATA='/Library/Application Support/Cellmori'
PLIST='/Library/LaunchDaemons/io.cellmori.helper.plist'
check_directory() {
  if [[ -e "$1" || -L "$1" ]]; then
    [[ -d "$1" && ! -L "$1" && "$(stat -f '%u' "$1")" = 0 ]] || { echo "不安全的目录：$1"; exit 1; }
    local mode
    mode=$(stat -f '%Lp' "$1")
    (( (8#$mode & 8#022) == 0 )) || { echo "目录可被非管理员写入：$1"; exit 1; }
  else
    install -d -o root -g wheel -m 755 "$1"
  fi
}
check_directory '/Library/PrivilegedHelperTools'
check_directory "$DATA"
[[ ! -L "$HELPER" && ! -L "$PLIST" ]] || { echo '安装目标不能为符号链接'; exit 1; }
if [[ -f "$HELPER" ]]; then
  [[ "$(stat -f '%u' "$HELPER")" = 0 ]] || { echo '现有服务所有者异常'; exit 1; }
  mode=$(stat -f '%Lp' "$HELPER")
  (( (8#$mode & 8#022) == 0 )) || { echo '现有服务权限异常'; exit 1; }
fi
# Bind the privileged channel to this exact ad-hoc signed app and installing console user.
# App identifiers alone are forgeable; hash requirements are enforced for every XPC message.
APP="$SOURCE_DIR/../.."
codesign --verify --deep --strict "$APP"
CLIENT_HASH=$(codesign -d --verbose=4 "$APP" 2>&1 | sed -n 's/^CDHash=//p')
HELPER_HASH=$(codesign -d --verbose=4 "$SOURCE_DIR/cellmori-helper" 2>&1 | sed -n 's/^CDHash=//p')
CONSOLE_UID=$(stat -f '%u' /dev/console)
[[ "$CLIENT_HASH" =~ ^[0-9a-fA-F]{40}$ && "$HELPER_HASH" =~ ^[0-9a-fA-F]{40}$ && "$CONSOLE_UID" =~ ^[0-9]+$ && "$CONSOLE_UID" -ge 501 ]] || { echo '无法确认应用签名或当前登录账户'; exit 1; }
[[ ! -L "$DATA/client-identity.plist" ]] || { echo '通信身份文件不能是符号链接'; exit 1; }
# Serialize installers independently from the policy lock, which an old daemon
# may hold forever. Never steal a lock from a live installer.
INSTALL_LOCK="$DATA/install.lock"
[[ ! -L "$INSTALL_LOCK" ]] || { echo '安装锁不能为符号链接'; exit 1; }
# lockf's descriptor form locks the shared open-file description, so the
# parent shell retains it after lockf exits. Keep the inode; the OS releases
# the lock automatically when descriptors close, including after a crash.
exec 9>"$INSTALL_LOCK"
/usr/bin/lockf -s -t 0 9 || { echo '已有后台安装正在执行，请等待该安装结束。'; exit 1; }
STAGED=''
CM_INSTALL_CHILD=''
cleanup() {
  if [[ -n "$CM_INSTALL_CHILD" ]]; then
    kill -TERM "$CM_INSTALL_CHILD" 2>/dev/null || true
    kill -KILL "$CM_INSTALL_CHILD" 2>/dev/null || true
    wait "$CM_INSTALL_CHILD" 2>/dev/null || true
  fi
  [[ -z "$STAGED" ]] || rm -f "$STAGED"
  exec 9>&-
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# A unique root-owned copy avoids collisions with an interrupted older install.
STAGED=$(mktemp /Library/PrivilegedHelperTools/io.cellmori.helper.stage.XXXXXX)
install -o root -g wheel -m 755 "$SOURCE_DIR/cellmori-helper" "$STAGED"
source "$SOURCE_DIR/installer-support.sh"
cm_prepare_upgrade "$STAGED" "$HELPER"
mv -f "$STAGED" "$HELPER"
cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>io.cellmori.helper</string>
<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/io.cellmori.helper</string><string>serve</string></array>
<key>MachServices</key><dict><key>io.cellmori.helper.control</key><true/></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>15</integer>
<key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
IDENTITY_TMP=$(mktemp "$DATA/identity.XXXXXX")
cat > "$IDENTITY_TMP" <<IDENTITY
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>clientHash</key><string>$CLIENT_HASH</string>
<key>helperHash</key><string>$HELPER_HASH</string>
<key>userID</key><integer>$CONSOLE_UID</integer>
</dict></plist>
IDENTITY
chown root:wheel "$IDENTITY_TMP"
chmod 644 "$IDENTITY_TMP"
mv -f "$IDENTITY_TMP" "$DATA/client-identity.plist"
launchctl bootstrap system "$PLIST"
echo '后台服务已安装；首次安装默认由系统管理，更新保留现有策略。'
