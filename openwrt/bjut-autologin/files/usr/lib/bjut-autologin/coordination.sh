#!/bin/sh
# SPDX-License-Identifier: MIT
# Reservations serialize slot allocation across parallel uplink workers.
account_reserve() {
 local section="$1" user limit key lock owner now item state assigned count=0 hash expiry device address seen='' signature
 config_get user "$section" username ''
 config_get limit "$section" max_sessions 0
 valid_range "$limit" 0 32 || return 1
 [ "$limit" -gt 0 ] || return 0
 key="$(printf '%s' "${user%@campus}" | sha256sum | awk '{print $1}')"
 lock="$STATE_DIR/account-$key.lock"; now="$(date +%s)"
 if ! mkdir "$lock" 2>/dev/null; then
  owner="$(cat "$lock/pid" 2>/dev/null)"
  is_uint "$owner" && kill -0 "$owner" 2>/dev/null && return 1
  rm -rf "$lock"; mkdir "$lock" 2>/dev/null || return 1
 fi
 printf '%s' "$$" >"$lock/pid"
 for item in $UPLINK_SECTIONS; do
  [ "$item" != "$UPLINK_ID" ] || continue
  assigned="$(json_file_value "$STATE_DIR/uplink-$item.json" '@.account')"
  state="$(json_file_value "$STATE_DIR/uplink-$item.json" '@.state')"
  device="$(json_file_value "$STATE_DIR/uplink-$item.json" '@.device')"; address="$(json_file_value "$STATE_DIR/uplink-$item.json" '@.ipv4')"
  signature="$device:$address"
  case "$state" in online|authenticated_limited|probe_uncertain|login_accepted)
   if [ -n "$assigned" ] && [ "${assigned%@campus}" = "${user%@campus}" ]; then
    case "|$seen|" in *"|$signature|"*) ;; *) count=$((count+1)); seen="$seen|$signature";; esac
    continue
   fi;;
  esac
  hash=''; expiry=0
  [ ! -r "$STATE_DIR/reservation-$item" ] || read -r hash expiry <"$STATE_DIR/reservation-$item"
  if [ "$hash" = "$key" ] && is_uint "$expiry" && [ "$expiry" -gt "$now" ]; then count=$((count+1)); fi
 done
 if [ "$count" -ge "$limit" ]; then rm -rf "$lock"; return 1; fi
 printf '%s %s\n' "$key" "$((now+120))" >"$STATE_DIR/reservation-$UPLINK_ID.$$" && mv -f "$STATE_DIR/reservation-$UPLINK_ID.$$" "$STATE_DIR/reservation-$UPLINK_ID"
 rm -rf "$lock"
}

account_release() { rm -f "$STATE_DIR/reservation-$UPLINK_ID"; }
