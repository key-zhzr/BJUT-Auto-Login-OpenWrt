#!/bin/sh
# SPDX-License-Identifier: MIT
# Destinations are configured locally; RPC clients cannot supply a file to read.
valid_log_directory() {
 case "$1" in /tmp/*|/var/log/*|/mnt/*|/media/*|/overlay/*|/srv/*|/data/*|"$STATE_DIR"/*) ;; *) return 1;; esac
 case "$1" in *[!A-Za-z0-9_./-]*|*/../*|*/..|*/./*|*/.|*//*|*/) return 1;; esac
 [ "${#1}" -le 240 ]
}
prepare_router_identity() {
 local directory="${BJUT_DATA_DIR:-/etc/bjut-autologin}" web="${BJUT_WEB_ROOT:-/www}" identity temporary
 mkdir -p "$directory" "$web/.well-known" || return 1
 chmod 0700 "$directory" || return 1
 identity="$(cat "$directory/router-id" 2>/dev/null)"
 case "$identity" in ''|*[!0-9a-f]*) identity="";; esac
 if [ "${#identity}" != 32 ]; then
  identity="$("$CODEC_BIN" random16)" || return 1
  [ "${#identity}" = 32 ] || return 1
  temporary="$(mktemp "$directory/identity.XXXXXX")" || return 1
  printf '%s\n' "$identity" >"$temporary" && chmod 0600 "$temporary" && mv -f "$temporary" "$directory/router-id" || return 1
 fi
 temporary="$(mktemp "$web/.well-known/bjut.XXXXXX")" || return 1
 printf '{"product":"BJUT-Auto-Login-OpenWrt","apiVersion":1,"version":"%s","revision":11,"name":"BJUT 路由器","apiPath":"/ubus","routerId":"%s","features":["dashboard","network_binding","uplink_actions","billing_actions"]}\n' "$VERSION" "$identity" >"$temporary" && chmod 0644 "$temporary" && mv -f "$temporary" "$web/.well-known/bjut-autologin.json"
}
prepare_file_log() {
 local directory="${CFG_LOG_DIRECTORY:-/tmp/bjut-autologin-log}" path link old owner="${BJUT_DATA_DIR:-/etc/bjut-autologin}/web-log-target"
 valid_log_directory "$directory" || return 1
 mkdir -p "$directory" || return 1
 path="$directory/bjut-autologin.log"
 [ ! -L "$path" ] && [ ! -L "$path.1" ] || return 1
 [ -f "$path" ] || (umask 077; : >"$path") || return 1
 chmod 0600 "$path" || return 1
 link="${BJUT_WEB_ROOT:-/www}/bjut-autologin.log"; old="$(cat "$owner" 2>/dev/null)"
 if [ "${CFG_LOG_WEB:-0}" = 1 ]; then
  if [ -e "$link" ] || [ -L "$link" ]; then
   [ -L "$link" ] && { [ "$(readlink "$link")" = "$old" ] || [ "$(readlink "$link")" = "$path" ]; } || return 1
  fi
  mkdir -p "$(dirname "$owner")" "${BJUT_WEB_ROOT:-/www}" || return 1
  ln -sf "$path" "$link" || return 1
  (umask 077; printf '%s\n' "$path" >"$owner") || return 1
 elif [ -n "$old" ] && [ -L "$link" ] && [ "$(readlink "$link")" = "$old" ]; then rm -f "$link" "$owner"; fi
 LOG_FILE="$path"
}
prepare_log_destination() {
 local owner="${BJUT_DATA_DIR:-/etc/bjut-autologin}/web-log-target" link="${BJUT_WEB_ROOT:-/www}/bjut-autologin.log" old
 if [ "${CFG_LOG_TARGET:-system}" = file ];then prepare_file_log;return $?;fi
 old="$(cat "$owner" 2>/dev/null)"
 if [ -n "$old" ] && [ -L "$link" ] && [ "$(readlink "$link")" = "$old" ];then rm -f "$link" "$owner";fi
}
bjut_log_message() {
 local priority="$1" message="$2" configured="${CFG_LOG_LEVEL:-info}" required threshold size prefix
 case "$priority" in trace) required=0;; debug) required=1;; info) required=2;; notice) required=3;; warning) required=4;; *) required=5;; esac
 case "$configured" in trace) threshold=0;; debug) threshold=1;; info) threshold=2;; notice) threshold=3;; warning) threshold=4;; *) threshold=5;; esac
 [ "$required" -ge "$threshold" ] || return 0
 message="$(printf '%s' "$message" | awk 'tolower($0) ~ /(user_password|password|authorization|cookie|token)[=:]/ {print "[敏感日志已隐藏]"; next} { $0=substr($0,1,1200); gsub(/Type1_221_98|Type1|type1/,"bjut-sushe");gsub(/Type2_251_3|Type2|type2/,"bjut_wifi");gsub(/Type3_172_30|Type3|type3/,"lgn");print}')"
 prefix="[$priority] [${UPLINK_ID:-service}${DEVICE:+/$DEVICE}]"
 if [ "${CFG_LOG_TARGET:-system}" = file ] && prepare_file_log; then
  size="$(wc -c <"$LOG_FILE" | tr -d ' \011\012\015')"
  if is_uint "$size" && [ "$size" -ge "$(( ${CFG_LOG_MAX_KB:-256} * 1024 ))" ]; then mv -f "$LOG_FILE" "$LOG_FILE.1"; (umask 077; : >"$LOG_FILE"); fi
  printf '[%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$prefix" "$message" >>"$LOG_FILE"
 elif command_exists "$LOGGER_BIN"; then
  [ "$priority" != trace ] || priority=debug
  printf '%s %s\n' "$prefix" "$message" | "$LOGGER_BIN" -t "$TAG" -p "daemon.$priority" 2>/dev/null || true
 else printf '%s: %s %s\n' "$TAG" "$prefix" "$message" >&2; fi
}
