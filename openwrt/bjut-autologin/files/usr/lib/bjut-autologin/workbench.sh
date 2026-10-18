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
 local section key value comma="" network i=0 dump
 printf '{"service":'
 json_init
 for key in enabled transport login_type compatibility strict_network expected_ssid expected_bssid interval timeout offline_confirmations max_backoff credential_cooldown post_login_delay online_url online_code managed_routes mwan3 log_level log_target log_directory log_web log_max_kb; do
  case "$key" in
   enabled) value="$CFG_ENABLED";; interval) value="$CFG_INTERVAL";; timeout) value="$CFG_TIMEOUT";; offline_confirmations) value="$CFG_OFFLINE_CONFIRMATIONS";;
   managed_routes) value="$CFG_MANAGED_ROUTES";; mwan3) value="$CFG_MWAN3";; log_level) value="$CFG_LOG_LEVEL";; log_target) value="$CFG_LOG_TARGET";; log_directory) value="$CFG_LOG_DIRECTORY";; log_web) value="$CFG_LOG_WEB";; log_max_kb) value="$CFG_LOG_MAX_KB";;
   max_backoff) value="$CFG_MAX_BACKOFF";; credential_cooldown) value="$CFG_CREDENTIAL_COOLDOWN";; post_login_delay) value="$CFG_POST_LOGIN_DELAY";;
   *) config_get value "$MAIN_SECTION" "$key" "";;
  esac
  [ "$key" != login_type ] || value="$(protocol_name "$value")"
  json_add_string "$key" "$value"
 done
 json_dump; printf ',"uplinks":['; comma=""
 for section in $UPLINK_SECTIONS; do
  [ "$section" != main ] || [ "$UPLINK_CONFIGURED" = 1 ] || continue
  json_init; json_add_string id "$section"
  for key in enabled network network6 device device6 source4 source6 transport login_type accounts expected_ssid expected_bssid; do
   config_get value "$section" "$key" ""; [ "$key" != login_type ] || value="$(protocol_name "$value")"
   json_add_string "$key" "$value"
  done
  printf '%s' "$comma"; comma=,; json_dump
 done
 printf '],"networks":['; comma=""
 dump="$("$UBUS_BIN" -S call network.interface dump 2>/dev/null)"
 while [ "$i" -lt 64 ]; do
  network="$(network_json_value "$dump" "@.interface[$i].interface")"; [ -n "$network" ] || break
  if valid_device_name "$network"; then json_init; json_add_string id "$network"; printf '%s' "$comma"; comma=,; json_dump; fi
  i=$((i+1))
 done
 printf ']}\n'
}

workbench_logs() {
 local text
 text="$( { if [ "${CFG_LOG_TARGET:-system}" = file ] && valid_log_directory "$CFG_LOG_DIRECTORY" && [ -f "$CFG_LOG_DIRECTORY/bjut-autologin.log" ] && [ ! -L "$CFG_LOG_DIRECTORY/bjut-autologin.log" ]; then tail -n 500 "$CFG_LOG_DIRECTORY/bjut-autologin.log"; else logread -e "$TAG" 2>/dev/null | tail -n 500; fi; } |
  awk 'tolower($0) ~ /(user_password|password|authorization|cookie|token)[=:]/ {print "[敏感日志已隐藏]"; next} { $0=substr($0,1,1024);gsub(/Type1_221_98|Type1|type1/,"bjut-sushe");gsub(/Type2_251_3|Type2|type2/,"bjut_wifi");gsub(/Type3_172_30|Type3|type3/,"lgn");print}')"
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
  [ "$key" != login_type ] || value="$(protocol_internal "$value")"
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

workbench_validate_field() {
 local key="$1" value="$2"
 [ "${#value}" -le 4096 ] || return 1
 case "$value" in *'
'*|*"$(printf '\r')"*) return 1;; esac
 case "$key" in
  enabled|managed_routes|mwan3|strict_network|log_web) case "$value" in 0|1) return 0;; esac;;
  interval) is_uint "$value" && [ "$value" -ge 5 ] && [ "$value" -le 3600 ]; return $?;;
  timeout) is_uint "$value" && [ "$value" -ge 1 ] && [ "$value" -le 30 ]; return $?;;
  offline_confirmations) is_uint "$value" && [ "$value" -ge 1 ] && [ "$value" -le 10 ]; return $?;;
  max_backoff) is_uint "$value" && [ "$value" -ge 5 ] && [ "$value" -le 86400 ]; return $?;;
  credential_cooldown) is_uint "$value" && [ "$value" -ge 30 ] && [ "$value" -le 86400 ]; return $?;;
  post_login_delay) is_uint "$value" && [ "$value" -le 15 ]; return $?;;
  online_code) is_uint "$value" && [ "$value" -ge 100 ] && [ "$value" -le 599 ]; return $?;;
  log_level) case "$value" in trace|debug|info|notice|warning|error) return 0;; esac;;
  log_target) case "$value" in system|file) return 0;; esac;;
  log_directory) valid_log_directory "$value"; return $?;;
  log_max_kb) valid_range "$value" 64 4096; return $?;;
  transport) case "$value" in auto|wifi|ethernet) return 0;; esac;;
  login_type) case "$value" in auto|type1|type2|type3|bjut-sushe|bjut_wifi|lgn) return 0;; esac;;
  compatibility) case "$value" in secure|legacy_http) return 0;; esac;;
  network|network6|device|device6) [ -z "$value" ] || valid_device_name "$value"; return $?;;
  source4) [ -z "$value" ] || printf '%s' "$value" | "$CODEC_BIN" validate-ipv4 >/dev/null 2>&1; return $?;;
  source6) [ -z "$value" ] || printf '%s' "$value" | "$CODEC_BIN" validate-ipv6 >/dev/null 2>&1; return $?;;
  expected_ssid) [ "${#value}" -le 128 ]; return $?;;
  expected_bssid) [ -z "$value" ] || printf '%s' "$value" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'; return $?;;
  online_url) valid_http_url "$value"; return $?;;
  accounts) for account in $value; do case " $ACCOUNT_SECTIONS " in *" $account "*) ;; *) return 1;; esac; done; return 0;;
 esac
 return 1
}

workbench_save_settings() {
 local key value keys interval backoff
 json_load "$(cat "$REQUEST")" || { reply error "设置内容无效"; return; }; json_get_keys keys
 [ -n "$keys" ] || { reply error "没有要保存的设置"; return; }
 for key in $keys; do
  case "$key" in enabled|transport|login_type|compatibility|strict_network|expected_ssid|expected_bssid|interval|timeout|offline_confirmations|max_backoff|credential_cooldown|post_login_delay|online_url|online_code|managed_routes|mwan3|log_level|log_target|log_directory|log_web|log_max_kb) ;; *) reply error "设置项无效"; return;; esac
  value="$(request_value "$key")"; workbench_validate_field "$key" "$value" || { reply error "请检查设置内容"; return; }
 done
 interval="$(request_value interval)"; interval="${interval:-$CFG_INTERVAL}"
 backoff="$(request_value max_backoff)"; backoff="${backoff:-$CFG_MAX_BACKOFF}"
 [ "$interval" -le "$backoff" ] || { reply error "最大重试间隔不能小于检测间隔"; return; }
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

# Transactions stage only this application's UCI package. Passwords never enter
# process arguments, read-only responses or runtime logs.
workbench_stage() {
 original="${BJUT_CONFIG_DIR:-/etc/config}/bjut-autologin"
 configuration_lock || { reply error "另一项设置正在保存，请稍后重试"; return 1; }
 [ -z "$("$UCI_BIN" -q changes bjut-autologin 2>/dev/null)" ] || { reply error "请先应用待保存的设置"; return 1; }
 stage="$(mktemp -d "$STATE_DIR/edit.XXXXXX")" || return 1
 package="bjut_edit_$$"
 cp "$original" "$stage/$package" && cp "$original" "$stage/original"
}
workbench_finish() {
 local newfile result=0
 if cmp -s "$stage/original" "$original" && [ -z "$("$UCI_BIN" -q changes bjut-autologin 2>/dev/null)" ]; then
  "$UCI_BIN" -q -c "$stage" commit "$package" && newfile="$(mktemp "$original.bjut.XXXXXX")" &&
  cp "$stage/$package" "$newfile" && chmod 0600 "$newfile" && mv -f "$newfile" "$original" || result=1
 else result=1; fi
 [ -z "$newfile" ] || rm -f "$newfile"; rm -rf "$stage"
 if [ "$result" = 0 ]; then
  [ ! -x "${BJUT_INIT:-/etc/init.d/bjut-autologin}" ] || "${BJUT_INIT:-/etc/init.d/bjut-autologin}" reload >/dev/null 2>&1
  reply ready "路由器设置已保存"
 else reply error "设置未保存，请稍后重试"; fi
}
workbench_set() {
 { printf 'set %s.%s.%s=' "$package" "$1" "$2"; uci_quote "$3"; printf '\n'; } | "$UCI_BIN" -q -c "$stage" batch
}
workbench_account_save() {
 local account username password enabled login_type stage package original new=0 item existing count=0
 account="$(request_value account)"; username="$(request_value username)"; password="$(request_value password)"
 enabled="$(request_value enabled)"; login_type="$(request_value login_type)"
 case "$username" in ''|*[!A-Za-z0-9_@.,-]*) reply error "账号格式无效"; return;; esac
 [ "${#username}" -le 256 ] && [ "${#password}" -le 4096 ] || { reply error "账号或密码过长"; return; }
 case "$password" in *'
'*|*"$(printf '\r')"*) reply error "密码格式无效"; return;; esac
 workbench_validate_field enabled "$enabled" && workbench_validate_field login_type "$login_type" || { reply error "账号设置无效"; return; }
 for item in $ACCOUNT_SECTIONS; do
  count=$((count+1)); config_get existing "$item" username ""
  [ "$item" = "$account" ] || [ "$existing" != "$username" ] || { reply error "该账号已存在，请直接编辑"; return; }
 done
 if [ -z "$account" ]; then [ "$count" -lt 32 ] || { reply error "最多保存 32 个账号"; return; }; account="$(workbench_new_id)" || { reply error "无法创建账号，请更新路由端"; return; }; new=1; [ -n "$password" ] || { reply error "请填写密码"; return; }
 else case " $ACCOUNT_SECTIONS " in *" $account "*) ;; *) reply error "账号不存在"; return;; esac; fi
 workbench_stage || return
 if [ "$new" = 1 ]; then "$UCI_BIN" -q -c "$stage" set "$package.$account=account" || { rm -rf "$stage"; return 1; }; fi
 workbench_set "$account" username "$username" && workbench_set "$account" enabled "$enabled" && workbench_set "$account" login_type "$(protocol_internal "$login_type")" || { rm -rf "$stage"; return 1; }
 [ -z "$password" ] || workbench_set "$account" password "$password" || { rm -rf "$stage"; return 1; }
 password=""; workbench_finish
}
workbench_account_delete() {
 local account section kept value item stage package original
 account="$(request_value account)"; case " $ACCOUNT_SECTIONS " in *" $account "*) ;; *) reply error "账号不存在"; return;; esac
 workbench_stage || return
 "$UCI_BIN" -q -c "$stage" delete "$package.$account" || { rm -rf "$stage"; return 1; }
 for section in $UPLINK_SECTIONS "$MAIN_SECTION"; do
  config_get value "$section" accounts ""; kept=""
  for item in $value; do [ "$item" = "$account" ] || kept="$kept${kept:+ }$item"; done
  [ "$kept" = "$value" ] || workbench_set "$section" accounts "$kept" || { rm -rf "$stage"; return 1; }
 done
 workbench_finish
}
workbench_account_move() {
 local account direction previous="" next="" found=0 item target index stage package original
 account="$(request_value account)"; direction="$(request_value direction)"
 case "$direction" in up|down) ;; *) reply error "排序方向无效"; return;; esac
 for item in $ACCOUNT_SECTIONS; do
  if [ "$item" = "$account" ]; then found=1; continue; fi
  if [ "$found" = 0 ]; then previous="$item"; elif [ -z "$next" ]; then next="$item"; fi
 done
 [ "$found" = 1 ] || { reply error "账号不存在"; return; }
 target="$previous"; [ "$direction" != down ] || target="$next"
 [ -n "$target" ] || { reply ready "账号已位于此处"; return; }
 workbench_stage || return
 index="$("$UCI_BIN" -q -c "$stage" show "$package" | awk -v prefix="$package." -v wanted="$target" 'BEGIN{i=0} index($0,prefix)==1 {key=substr($0,length(prefix)+1);sub(/=.*/,"",key);if(key !~ /\./){if(key==wanted)print i;i++}}')"
 is_uint "$index" && "$UCI_BIN" -q -c "$stage" reorder "$package.$account=$index" || { rm -rf "$stage"; reply error "排序未保存"; return; }
 workbench_finish
}
workbench_uplink_save() {
 local uplink payload patch key value keys stage package original new=0 count=0 item
 uplink="$(request_value uplink)"; payload="$(request_value payload)"
 patch="$(mktemp "$STATE_DIR/uplink-edit.XXXXXX")" || return 1; printf '%s' "$payload" >"$patch"
 json_load "$payload" && json_get_keys keys || { rm -f "$patch"; reply error "上游设置无效"; return; }
 for key in $keys; do
  case "$key" in enabled|network|network6|device|device6|source4|source6|transport|login_type|accounts|expected_ssid|expected_bssid) ;; *) rm -f "$patch"; reply error "上游设置项无效"; return;; esac
  value="$(json_file_value "$patch" "@.$key")"; workbench_validate_field "$key" "$value" || { rm -f "$patch"; reply error "请检查上游设置"; return; }
 done
 [ -n "$(json_file_value "$patch" '@.network')" ] || { rm -f "$patch"; reply error "请选择 IPv4 接口"; return; }
 for item in $UPLINK_SECTIONS; do [ "$item" = "$MAIN_SECTION" ] || count=$((count+1)); done
 if [ -z "$uplink" ]; then [ "$count" -lt 16 ] || { rm -f "$patch"; reply error "最多配置 16 条上游"; return; }; uplink="$(workbench_new_id)" || { rm -f "$patch"; reply error "无法创建上游，请更新路由端"; return; }; new=1
 else case " $UPLINK_SECTIONS " in *" $uplink "*) [ "$uplink" != "$MAIN_SECTION" ] || { rm -f "$patch"; reply error "请在服务设置中修改旧版上游"; return; };; *) rm -f "$patch"; reply error "上游不存在"; return;; esac; fi
 workbench_stage || { rm -f "$patch"; return; }
 if [ "$new" = 1 ]; then "$UCI_BIN" -q -c "$stage" set "$package.$uplink=uplink" || { rm -rf "$stage"; rm -f "$patch"; return 1; }; fi
 for key in $keys; do
  value="$(json_file_value "$patch" "@.$key")"; [ "$key" != login_type ] || value="$(protocol_internal "$value")"
  workbench_set "$uplink" "$key" "$value" || { rm -rf "$stage"; rm -f "$patch"; return 1; }
 done
 rm -f "$patch"; workbench_finish
}
workbench_uplink_delete() {
 local uplink stage package original
 uplink="$(request_value uplink)"; case " $UPLINK_SECTIONS " in *" $uplink "*) [ "$uplink" != "$MAIN_SECTION" ] || { reply error "请修改旧版上游设置"; return; };; *) reply error "上游不存在"; return;; esac
 workbench_stage || return
 "$UCI_BIN" -q -c "$stage" delete "$package.$uplink" || { rm -rf "$stage"; return 1; }
 workbench_finish
}

workbench_new_id() { local token; token="$(random_ticket)"; valid_ticket "$token" || return 1; printf 'app_%s' "$(printf '%s' "$token" | cut -c1-16)"; }
