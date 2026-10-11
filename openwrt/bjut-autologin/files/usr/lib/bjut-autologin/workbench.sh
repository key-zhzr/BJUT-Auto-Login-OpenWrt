#!/bin/sh
# SPDX-License-Identifier: MIT
# Named, bounded App operations. Never expose saved passwords or arbitrary UCI.

port_metric() {
 local value
 valid_device_name "$1" || { printf '0'; return; }
 value="$(cat "$SYS_NET/$1/$2" 2>/dev/null)"
 is_uint "$value" || value=0
 printf '%s' "$value"
}

workbench_ports() {
 local section file device network comma="" status
 printf '{"ports":['
 for section in $UPLINK_SECTIONS; do
  file="$STATE_DIR/uplink-$section.json"
  [ "$section" != main ] || [ "$UPLINK_CONFIGURED" = 1 ] || file="$STATE_DIR/status.json"
  device="$(json_file_value "$file" '@.device')"
  network="$(json_file_value "$file" '@.network')"
  if ! valid_device_name "$device"; then
   config_get device "$section" device ""
   config_get network "$section" network ""
   if ! valid_device_name "$device" && valid_device_name "$network"; then
    status="$("$UBUS_BIN" -S call "network.interface.$network" status 2>/dev/null)"
    device="$(network_json_value "$status" '@.l3_device')"
   fi
  fi
  valid_device_name "$device" || device=""
  json_init; json_add_string uplink "$section"; json_add_string device "$device"
  json_add_int linkUp "$(port_metric "$device" carrier)"
  json_add_string speedMbps "$(port_metric "$device" speed)"
  json_add_string rxBytes "$(port_metric "$device" statistics/rx_bytes)"
  json_add_string txBytes "$(port_metric "$device" statistics/tx_bytes)"
  printf '%s' "$comma"; comma=,; json_dump
 done
 printf ']}\n'
}

workbench_settings() {
 local section key value comma=""
 printf '{"service":'
 json_init
 for key in enabled interval timeout offline_confirmations managed_routes mwan3 log_level; do
  case "$key" in
   enabled) value="$CFG_ENABLED" ;; interval) value="$CFG_INTERVAL" ;;
   timeout) value="$CFG_TIMEOUT" ;; offline_confirmations) value="$CFG_OFFLINE_CONFIRMATIONS" ;;
   managed_routes) value="$CFG_MANAGED_ROUTES" ;; mwan3) value="$CFG_MWAN3" ;;
   log_level) value="$CFG_LOG_LEVEL" ;;
  esac
  json_add_string "$key" "$value"
 done
 json_dump
 printf ',"uplinks":['
 for section in $UPLINK_SECTIONS; do
  json_init; json_add_string id "$section"
  for key in network network6 device device6 accounts; do
   config_get value "$section" "$key" ""
   json_add_string "$key" "$value"
  done
  printf '%s' "$comma"; comma=,; json_dump
 done
 printf ']}\n'
}

workbench_logs() {
 local text
 text="$(logread -e "$TAG" 2>/dev/null | tail -n 120 | cut -c1-1024 |
  awk 'tolower($0) ~ /(user_password|password|authorization|cookie|token)[=:]/ {print "[敏感日志已隐藏]"; next} {print}')"
 json_init; json_add_string text "$text"; json_dump
}

workbench_commit() {
 local stage original package newfile result=0 key value section="$1"
 shift
 original="${BJUT_CONFIG_DIR:-/etc/config}/bjut-autologin"
 configuration_lock || { reply error "另一项设置正在保存，请稍后重试"; return; }
 [ -z "$("$UCI_BIN" -q changes bjut-autologin 2>/dev/null)" ] || { reply error "请先应用路由器中待保存的设置"; return; }
 stage="$(mktemp -d "$STATE_DIR/workbench.XXXXXX")" || return 1
 package="bjut_app_$$"
 cp "$original" "$stage/$package" && cp "$original" "$stage/original" || { rm -rf "$stage"; return 1; }
 for key in "$@"; do
  value="$(request_value "$key")"
  [ -n "$value" ] || continue
  { printf 'set %s.%s.%s=' "$package" "$section" "$key"; uci_quote "$value"; printf '\n'; } |
   "$UCI_BIN" -q -c "$stage" batch || { result=1; break; }
 done
 if [ "$result" = 0 ] && cmp -s "$stage/original" "$original"; then
  "$UCI_BIN" -q -c "$stage" commit "$package" &&
  "$UCI_BIN" -q -c "$stage" export "$package" >/dev/null &&
  [ -z "$("$UCI_BIN" -q changes bjut-autologin 2>/dev/null)" ] &&
  newfile="$(mktemp "$original.bjut.XXXXXX")" && cp "$stage/$package" "$newfile" &&
  chmod 0600 "$newfile" && mv -f "$newfile" "$original" || result=1
 else result=1; fi
 "$UCI_BIN" -q -c "$stage" revert "$package" >/dev/null 2>&1 || true
 [ -z "$newfile" ] || rm -f "$newfile"
 rm -rf "$stage"
 if [ "$result" = 0 ]; then
  [ ! -x "${BJUT_INIT:-/etc/init.d/bjut-autologin}" ] || "${BJUT_INIT:-/etc/init.d/bjut-autologin}" reload >/dev/null 2>&1
  reply ready "路由器设置已保存"
 else reply error "设置未保存，请稍后重试"; fi
}

workbench_save_settings() {
 local key value keys
 json_load "$(cat "$REQUEST")" || { reply error "设置内容无效"; return; }
 json_get_keys keys
 [ -n "$keys" ] || { reply error "没有要保存的设置"; return; }
 for key in $keys; do
  value="$(request_value "$key")"
  case "$key" in
   enabled|managed_routes|mwan3) case "$value" in 0|1) ;; *) reply error "请选择开关状态"; return ;; esac ;;
   interval) is_uint "$value" && [ "$value" -ge 5 ] && [ "$value" -le 3600 ] || { reply error "检测间隔应为 5 至 3600 秒"; return; }
    [ "$value" -le "$CFG_MAX_BACKOFF" ] || { reply error "请先在更多设置中增大最大重试间隔"; return; } ;;
   timeout) is_uint "$value" && [ "$value" -ge 1 ] && [ "$value" -le 30 ] || { reply error "超时应为 1 至 30 秒"; return; } ;;
   offline_confirmations) is_uint "$value" && [ "$value" -ge 1 ] && [ "$value" -le 10 ] || { reply error "离线确认次数应为 1 至 10"; return; } ;;
   log_level) case "$value" in debug|info|notice|error) ;; *) reply error "日志级别无效"; return ;; esac ;;
   *) reply error "此设置请在路由器管理页面修改"; return ;;
  esac
 done
 workbench_commit "$MAIN_SECTION" $keys
}

configuration_lock() {
 local owner
 if ! mkdir "$STATE_DIR/config-lock" 2>/dev/null; then
  owner="$(cat "$STATE_DIR/config-lock/pid" 2>/dev/null)"
  is_uint "$owner" && kill -0 "$owner" 2>/dev/null && return 1
  rm -rf -- "$STATE_DIR/config-lock"
  mkdir "$STATE_DIR/config-lock" 2>/dev/null || return 1
 fi
 CONFIG_LOCK_HELD=1
 printf '%s' "$$" >"$STATE_DIR/config-lock/pid"
}

configuration_unlock() {
 [ "${CONFIG_LOCK_HELD:-0}" != 1 ] || rm -rf -- "$STATE_DIR/config-lock"
}

workbench_account_set() {
 local account enabled
 account="$(request_value account)"; enabled="$(request_value enabled)"
 case " $ACCOUNT_SECTIONS " in *" $account "*) ;; *) reply error "所选账号不存在"; return ;; esac
 case "$enabled" in 0|1) ;; *) reply error "请选择账号状态"; return ;; esac
 workbench_commit "$account" enabled
}
