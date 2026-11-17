#!/bin/bash
# SPDX-License-Identifier: MIT
# Shared by the root installer and isolated tests. No user-supplied commands.
cm_run_bounded() {
  local limit="$1" child step status
  shift
  "$@" &
  child=$!
  CM_INSTALL_CHILD="$child"
  for ((step=0; step<limit*5; step++)); do
    if ! kill -0 "$child" 2>/dev/null; then
      if wait "$child"; then status=0; else status=$?; fi
      CM_INSTALL_CHILD=
      return "$status"
    fi
    /bin/sleep 0.2
  done
  kill -TERM "$child" 2>/dev/null || true
  /bin/sleep 0.2
  kill -KILL "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  CM_INSTALL_CHILD=
  return 124
}
cm_service_exists() { /bin/launchctl print system/io.cellmori.helper >/dev/null 2>&1; }
cm_stop_service() {
  if cm_service_exists; then
    cm_run_bounded 8 /bin/launchctl bootout system/io.cellmori.helper 2>/dev/null || true
    if cm_service_exists; then
      cm_run_bounded 3 /bin/launchctl kill SIGKILL system/io.cellmori.helper 2>/dev/null || true
      cm_run_bounded 8 /bin/launchctl bootout system/io.cellmori.helper 2>/dev/null || true
    fi
  fi
  if cm_service_exists; then echo '旧后台未能停止，已中止更新。' >&2; return 1; fi
}
cm_prepare_upgrade() {
  local staged="$1" existing="$2"
  if [[ -f "$existing" ]]; then
    if ! cm_run_bounded 5 "$staged" prepare-update; then
      echo '旧后台交接未完成，正在停止旧服务并重新确认安全供电。'
    fi
  fi
  cm_stop_service || return 1
  if [[ -f "$existing" ]]; then
    # The old daemon no longer owns the policy lock. Only proceed after the new
    # helper has restored and verified the saved ceiling, adapter and sleep flag.
    if ! cm_run_bounded 10 "$staged" prepare-update; then
      echo '无法确认安全供电和原有上限，已中止更新；请重新运行安装包修复后台。' >&2
      return 1
    fi
  fi
}
