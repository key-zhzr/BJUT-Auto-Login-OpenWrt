#!/bin/sh
# SPDX-License-Identifier: MIT
# Direct children are registered with their kernel birth stamp before waiting.
process_identity() {
 local pid="$1" line tail i
 PROCESS_START=0;PROCESS_STATE='';PROCESS_PARENT=0
 if [ -r "/proc/$pid/stat" ];then
  IFS= read -r line <"/proc/$pid/stat" || return 1
  tail="${line##*) }";set -- $tail
  [ "$#" -ge 20 ] || return 1
  PROCESS_STATE="$1";PROCESS_PARENT="$2";i=19
  while [ "$i" -gt 0 ];do shift;i=$((i-1));done
  PROCESS_START="$1"
 else kill -0 "$pid" 2>/dev/null || return 1;fi
}
child_register() {
 local pid="$1"
 CHILD_PIDS="$CHILD_PIDS $pid"
 process_identity "$pid" || return 0
 CHILD_TOKENS="$CHILD_TOKENS $pid:$PROCESS_START"
}
child_forget() {
 local pid="$1" token kept=''
 for token in $CHILD_TOKENS;do case "$token" in "$pid":*) ;;*)kept="$kept $token";;esac;done
 CHILD_TOKENS="$kept";kept=''
 for token in $CHILD_PIDS;do [ "$token" = "$pid" ] || kept="$kept $token";done
 CHILD_PIDS="$kept"
}
child_signal() {
 local signal="$1" token pid stamp
 for token in $CHILD_TOKENS;do
  pid="${token%%:*}";stamp="${token#*:}"
  process_identity "$pid" || continue
  [ "$PROCESS_START" = "$stamp" ] && [ "$PROCESS_STATE" != Z ] || continue
  kill "-$signal" "$pid" 2>/dev/null || true
 done
}
children_stop() {
 local pid
 [ -n "$CHILD_PIDS" ] || return 0
 child_signal TERM
 if [ -x "$RUNTIME_BIN" ];then
  # One bounded native wait; no fractional BusyBox sleep loop or fork storm.
  "$RUNTIME_BIN" wait-children 1500 $CHILD_TOKENS >/dev/null 2>&1 || true
 else sleep 1;fi
 child_signal KILL
 for pid in $CHILD_PIDS;do wait "$pid" 2>/dev/null || true;done
 CHILD_PIDS='';CHILD_TOKENS=''
}
short_pause() {
 if [ -x "$RUNTIME_BIN" ];then "$RUNTIME_BIN" pause 50;else sleep 1;fi
}
# A short preparation offset keeps periodic uplinks from doing all local
# work at once. Explicit operations and immediate switch samples bypass it.
preparation_pause() {
 local slots="${1:-0}" bypass="${2:-}" pid rc
 case "$slots" in 0|1|2|3) ;;*)return 0;;esac
 [ -x "$RUNTIME_BIN" ] || return 0
 while [ "$slots" -gt 0 ];do
  [ ! -s "$bypass" ] || break
  "$RUNTIME_BIN" pause 750 & pid=$!
  child_register "$pid"
  wait "$pid";rc=$?
  child_forget "$pid"
  [ "$rc" = 0 ] || return "$rc"
  slots=$((slots-1))
 done
}
configuration_fingerprint() {
 "$RUNTIME_BIN" fingerprint "${BJUT_CONFIG_FILE:-${BJUT_CONFIG_DIR:-/etc/config}/$CONFIG_PACKAGE}" "${BJUT_CONFIG_DELTA:-/tmp/.uci/$CONFIG_PACKAGE}"
}

# One parser for a whole document. read assigns literal values, including
# quotes and backslashes; the result is never evaluated as shell code.
json_fields() {
 local fields_file="$1" projection field pair wanted value
 shift
 if [ "${BJUT_BATCH_DISABLE:-0}" != 1 ] && [ -x "$RUNTIME_BIN" ] && projection="$("$RUNTIME_BIN" fields "$fields_file" "$@")";then
  while IFS= read -r field;do
   [ "$field" != BJUT_FIELDS_END ] || break
   case "$field" in ''|*[!A-Za-z0-9_]*)return 1;;esac
   IFS= read -r "$field" || return 1
  done <<END_FIELDS
$projection
END_FIELDS
 else
  for pair in "$@";do
   wanted="${pair#*=}";field="${pair%%=*}"
   value="$(json_file_value "$fields_file" "$wanted")"
   read -r "$field" <<END_VALUE
$value
END_VALUE
  done
 fi
}
json_text_fields() {
 local fields_text="$1" projection field
 shift
 if [ "${BJUT_BATCH_DISABLE:-0}" != 1 ] && [ -x "$RUNTIME_BIN" ] && projection="$(printf '%s' "$fields_text" | "$RUNTIME_BIN" fields - "$@")";then
  while IFS= read -r field;do
   [ "$field" != BJUT_FIELDS_END ] || break
   case "$field" in ''|*[!A-Za-z0-9_]*)return 1;;esac
   IFS= read -r "$field" || return 1
  done <<END_FIELDS
$projection
END_FIELDS
 else
  local pair wanted value
  for pair in "$@";do
   wanted="${pair#*=}";field="${pair%%=*}"
   value="$(network_json_value "$fields_text" "$wanted")"
   IFS= read -r "$field" <<END_VALUE
$value
END_VALUE
  done
 fi
}

prepared_section_write() {
 local section="$1" type="$2" options option value
 valid_section "$section" || return 1
 case "$type" in
 service)options='enabled network network6 device device6 source4 source6 accounts mwan3 managed_routes transport login_type compatibility interval timeout offline_confirmations max_backoff credential_cooldown post_login_delay online_url online_code strict_network expected_ssid expected_bssid log_level log_target log_directory log_web log_max_kb pushplus_enabled pushplus_topic pushplus_online pushplus_failure pushplus_delay pushplus_interval billing_background billing_interval billing_alerts balance_threshold flow_threshold traffic_monitor traffic_scope traffic_minute_hours traffic_hour_days traffic_day_days traffic_storage_mb prefer_remaining_flow';;
 uplink)options='enabled network network6 device device6 source4 source6 accounts transport login_type compatibility expected_ssid expected_bssid';;
 account)options='enabled username login_type max_sessions';;
 *)return 1;;esac
 json_add_object "$section";json_add_string TYPE "$type"
 for option in $options;do config_get value "$section" "$option" '';json_add_string "$option" "$value";done
 if [ "$type" = account ];then
  account_metadata "$section" || return 1
  json_add_string bjut_key "$ACCOUNT_KEY";json_add_string bjut_signature "$ACCOUNT_SIGNATURE";json_add_string bjut_has_password "$ACCOUNT_HAS_PASSWORD"
 elif [ "$type" = service ];then
  config_get value "$section" pushplus_token '';option=0
  if [ -n "$value" ] && valid_pushplus_token "$value";then option=1;fi;value=''
  json_add_string bjut_pushplus_ready "$option"
 fi
 json_close_object
}
prepared_context_write() (
 [ "${BJUT_BATCH_DISABLE:-0}" != 1 ] && [ -x "$RUNTIME_BIN" ] && [ -n "$CONFIG_GENERATION" ] || return 75
 mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR" || return 1
 . "$JSHN_SH"
 # No secret is passed to jshn (which uses exported variables internally).
 {
  json_init;json_add_object sections
  prepared_section_write "$MAIN_SECTION" service
  local section
  for section in $ACCOUNT_SECTIONS;do prepared_section_write "$section" account;done
  if [ "$UPLINK_CONFIGURED" = 1 ];then for section in $UPLINK_SECTIONS;do prepared_section_write "$section" uplink;done;fi
  json_close_object;json_dump
 } | "$RUNTIME_BIN" prepare-config "$STATE_DIR/prepared-context.json" "${BJUT_CONFIG_FILE:-${BJUT_CONFIG_DIR:-/etc/config}/$CONFIG_PACKAGE}" "${BJUT_CONFIG_DELTA:-/tmp/.uci/$CONFIG_PACKAGE}" "$CONFIG_GENERATION"
)
prepared_context_load() {
 local projection field
 [ "${BJUT_PREPARED_CONFIG:-0}" = 1 ] && [ "${BJUT_BATCH_DISABLE:-0}" != 1 ] && [ -x "$RUNTIME_BIN" ] || return 75
 projection="$("$RUNTIME_BIN" prepared-config "$STATE_DIR/prepared-context.json" "${BJUT_CONFIG_FILE:-${BJUT_CONFIG_DIR:-/etc/config}/$CONFIG_PACKAGE}" "${BJUT_CONFIG_DELTA:-/tmp/.uci/$CONFIG_PACKAGE}")" || return 75
 configuration_values_clear
 while IFS= read -r field;do
  [ "$field" != BJUT_FIELDS_END ] || break
  case "$field" in CONFIG_* )case "$field" in *[!A-Za-z0-9_]*)return 75;;esac;;*)return 75;;esac
  IFS= read -r "$field" || return 75
 done <<END_PREPARED
$projection
END_PREPARED
 [ "${CONFIG_PREPARED:-0}" = 1 ]
}
configuration_values_clear() {
 local section option
 # uci_load resets section/list indexes, but leaves old scalar variables.
 # Remove this package's known values before either kind of reload, including
 # private memo fields, so deleted options/credentials cannot survive an edit.
 for section in $CONFIG_SECTIONS;do
  valid_section "$section" || continue
  for option in TYPE enabled network network6 device device6 source4 source6 accounts mwan3 managed_routes transport login_type compatibility interval timeout offline_confirmations max_backoff credential_cooldown post_login_delay online_url online_code strict_network expected_ssid expected_bssid log_level log_target log_directory log_web log_max_kb pushplus_enabled pushplus_token pushplus_topic pushplus_online pushplus_failure pushplus_delay pushplus_interval billing_background billing_interval billing_alerts balance_threshold flow_threshold traffic_monitor traffic_scope traffic_minute_hours traffic_hour_days traffic_day_days traffic_storage_mb prefer_remaining_flow username password max_sessions bjut_key bjut_signature bjut_has_password bjut_pushplus_ready;do
   unset "CONFIG_${section}_${option}"
  done
 done
}
configuration_unchanged() {
 [ -z "${CONFIG_GENERATION:-}" ] || [ "$(configuration_fingerprint)" = "$CONFIG_GENERATION" ]
}
credential_get() {
 local destination="$1" section="$2" option="${3:-password}"
 # Clear the destination on every failure, never continue with an old secret.
 IFS= read -r "$destination" <<END_EMPTY

END_EMPTY
 if [ "${CONFIG_PREPARED:-0}" = 1 ];then
  configuration_unchanged || return 1
  configuration_values_clear
  config_load "$CONFIG_PACKAGE" || return 1
  CONFIG_PREPARED=0
 fi
 config_get "$destination" "$section" "$option" ''
}
account_metadata() {
 local section="$1" user password
 config_get ACCOUNT_KEY "$section" bjut_key ''
 config_get ACCOUNT_SIGNATURE "$section" bjut_signature ''
 config_get ACCOUNT_HAS_PASSWORD "$section" bjut_has_password ''
 [ "${#ACCOUNT_KEY}" != 64 ] || [ "${#ACCOUNT_SIGNATURE}" != 64 ] || return 0
 config_get user "$section" username '';credential_get password "$section" || return 1
 if [ -x "$RUNTIME_BIN" ];then
  ACCOUNT_KEY="$(printf '%s' "$user" | "$RUNTIME_BIN" sha256)"
  ACCOUNT_SIGNATURE="$(printf '%s\n' "$user" "$password" | "$RUNTIME_BIN" sha256)"
 else
  ACCOUNT_KEY="$(printf '%s' "$user" | sha256sum | cut -d ' ' -f 1)"
  ACCOUNT_SIGNATURE="$(printf '%s\n' "$user" "$password" | sha256sum | cut -d ' ' -f 1)"
 fi
 ACCOUNT_HAS_PASSWORD=0;[ -z "$password" ] || ACCOUNT_HAS_PASSWORD=1;password=''
 IFS= read -r "CONFIG_${section}_bjut_key" <<END_KEY
$ACCOUNT_KEY
END_KEY
 IFS= read -r "CONFIG_${section}_bjut_signature" <<END_SIGNATURE
$ACCOUNT_SIGNATURE
END_SIGNATURE
 IFS= read -r "CONFIG_${section}_bjut_has_password" <<END_PRESENT
$ACCOUNT_HAS_PASSWORD
END_PRESENT
}

network_context_refresh() {
 [ "${BJUT_BATCH_DISABLE:-0}" != 1 ] && [ -x "$RUNTIME_BIN" ] && [ -n "$CONFIG_GENERATION" ] || return 75
 "$UBUS_BIN" -S call network.interface dump 2>/dev/null |
  "$RUNTIME_BIN" network-save "$STATE_DIR/network-context.json" "$CONFIG_GENERATION"
}
native_network_read() {
 local projection field
 [ "${BJUT_BATCH_DISABLE:-0}" != 1 ] && [ "${BJUT_NETWORK_FRESH:-0}" != 1 ] && [ -x "$RUNTIME_BIN" ] || return 75
 [ "$SYS_NET" = /sys/class/net ] || [ -n "${BJUT_NATIVE_ADDRESSES:-}" ] || return 75
 projection="$("$RUNTIME_BIN" network-read "$STATE_DIR/network-context.json" "$SYS_NET" "$CFG_NETWORK" "$CFG_DEVICE" "$CFG_NETWORK6" "$CFG_DEVICE6" "$CFG_SOURCE4" "$CFG_SOURCE6" "$CONFIG_GENERATION")" || return 75
 while IFS= read -r field;do
  [ "$field" != BJUT_FIELDS_END ] || break
  case "$field" in DEVICE|DEVICE6|LOCAL_IPV4|LOCAL_IPV6|IPV6_PD|NETWORK_JSON4|NETWORK_JSON6) ;;*)return 75;;esac
  IFS= read -r "$field" || return 75
 done <<END_NETWORK
$projection
END_NETWORK
}

# This private cache contains display metadata, never plaintext credentials.
# Its content fingerprint covers UCI edits and pending LuCI changes, including
# multiple changes in the same second. Consumers parse JSON, never source it.
view_context_write() (
 local signature="$1" temporary section user password key value comma='' option
 [ -x "$RUNTIME_BIN" ] && [ -n "$signature" ] || return 0
 # RPC already sources jshn; the independent daemon has no such caller.
 # Initialize inside this subshell so every publisher has the same contract.
 . "$JSHN_SH" || return 1
 temporary="$(mktemp "$STATE_DIR/view-context.XXXXXX")" || return 1
 trap 'rm -f "$temporary"' 0
 {
  json_init;json_add_int schema 1;json_add_string fingerprint "$signature";json_add_string version "$VERSION"
  json_add_int configured "$UPLINK_CONFIGURED";json_add_int interval "$CFG_INTERVAL";json_add_int trafficEnabled "$CFG_TRAFFIC_MONITOR";json_add_string scope "$CFG_TRAFFIC_SCOPE"
  json_add_object retention;json_add_int minuteHours "$CFG_TRAFFIC_MINUTE_HOURS";json_add_int hourDays "$CFG_TRAFFIC_HOUR_DAYS";json_add_int dayDays "$CFG_TRAFFIC_DAY_DAYS";json_add_int storageMb "$CFG_TRAFFIC_STORAGE_MB";json_close_object
  json_dump | sed 's/}[[:space:]]*$/,"uplinks":/'
  printf '['
  for section in $UPLINK_SECTIONS;do
   json_init;json_add_string id "$section";config_get value "$section" device '';json_add_string device "$value"
   printf '%s' "$comma";comma=,;json_dump
  done
  printf '],"accounts":[';comma=''
  for section in $ACCOUNT_SECTIONS;do
   config_get user "$section" username '';config_get password "$section" password ''
   key="$(printf '%s' "$user" | sha256sum | cut -d ' ' -f 1)"
   value="$(printf '%s\n' "$user" "$password" | sha256sum | cut -d ' ' -f 1)"
   json_init;json_add_string id "$section";json_add_string user "$user";json_add_string key "$key";json_add_string signature "$value"
   value=0;[ -z "$password" ] || value=1;password='';json_add_int hasPassword "$value"
   config_get_bool value "$section" enabled 1;json_add_int enabled "$value"
   config_get value "$section" login_type auto;json_add_string loginType "$(protocol_name "$value")"
   config_get value "$section" max_sessions 0;valid_range "$value" 0 32 || value=0;json_add_int configuredMaxSessions "$value"
   printf '%s' "$comma";comma=,;json_dump
  done
  printf ']}\n'
 } >"$temporary" || return 1
 json_load "$(cat "$temporary")" || return 1
 json_get_type value uplinks;[ "$value" = array ] || return 1
 json_get_type value accounts;[ "$value" = array ] || return 1
 [ "$(configuration_fingerprint)" = "$signature" ] || return 1
 chmod 0600 "$temporary" && mv -f "$temporary" "$STATE_DIR/view-context.json"
)
view_snapshot() {
 [ "${BJUT_SNAPSHOT_DISABLE:-0}" != 1 ] && [ -x "$RUNTIME_BIN" ] || return 75
 "$RUNTIME_BIN" snapshot "$1" "$REQUEST" "$STATE_DIR" "$SYS_NET" "${BJUT_CONFIG_FILE:-${BJUT_CONFIG_DIR:-/etc/config}/$CONFIG_PACKAGE}" "${BJUT_CONFIG_DELTA:-/tmp/.uci/$CONFIG_PACKAGE}"
}
