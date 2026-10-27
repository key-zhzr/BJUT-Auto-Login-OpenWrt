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
configuration_fingerprint() {
 "$RUNTIME_BIN" fingerprint "${BJUT_CONFIG_FILE:-${BJUT_CONFIG_DIR:-/etc/config}/$CONFIG_PACKAGE}" "${BJUT_CONFIG_DELTA:-/tmp/.uci/$CONFIG_PACKAGE}"
}

# This private cache contains display metadata, never plaintext credentials.
# Its content fingerprint covers UCI edits and pending LuCI changes, including
# multiple changes in the same second. Consumers parse JSON, never source it.
view_context_write() (
 local signature="$1" temporary section user password key value comma='' option
 [ -x "$RUNTIME_BIN" ] && [ -n "$signature" ] || return 0
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
 [ "$(configuration_fingerprint)" = "$signature" ] || return 1
 chmod 0600 "$temporary" && mv -f "$temporary" "$STATE_DIR/view-context.json"
)
view_snapshot() {
 [ "${BJUT_SNAPSHOT_DISABLE:-0}" != 1 ] && [ -x "$RUNTIME_BIN" ] || return 75
 "$RUNTIME_BIN" snapshot "$1" "$REQUEST" "$STATE_DIR" "$SYS_NET" "${BJUT_CONFIG_FILE:-${BJUT_CONFIG_DIR:-/etc/config}/$CONFIG_PACKAGE}" "${BJUT_CONFIG_DELTA:-/tmp/.uci/$CONFIG_PACKAGE}"
}
