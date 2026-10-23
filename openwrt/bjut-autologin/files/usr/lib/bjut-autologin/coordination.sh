#!/bin/sh
# SPDX-License-Identifier: MIT
# Reservations serialize slot allocation across parallel uplink workers.
account_session_active() {
 case "$1:$2" in *:online|online:*|authenticated_limited:*|probe_uncertain:*|login_accepted:*) return 0;; *) return 1;;esac
}
account_lock_acquire() {
 local lock="$1" candidate owner started
 candidate="$(mktemp "$STATE_DIR/account-owner.XXXXXX")" || return 1
 printf '%s\n' "$$" >"$candidate" || { rm -f "$candidate";return 1; }
 [ ! -d "$lock" ] || { rm -f "$candidate";return 1; }
 started="$(date +%s)"
 # Publish the initialized owner atomically, as with the shared route lock.
 while ! ln "$candidate" "$lock" 2>/dev/null;do
  [ ! -d "$lock" ] || { rm -f "$candidate";return 1; }
  owner="$(cat "$lock" 2>/dev/null)"
  if is_uint "$owner" && ! kill -0 "$owner" 2>/dev/null && mkdir "$lock.recover" 2>/dev/null;then
   owner="$(cat "$lock" 2>/dev/null)"
   if is_uint "$owner" && ! kill -0 "$owner" 2>/dev/null;then rm -f "$lock";fi
   rmdir "$lock.recover" 2>/dev/null || true
  fi
  if [ "$(($(date +%s)-started))" -ge 2 ];then rm -f "$candidate";return 1;fi
  sleep 0.05 2>/dev/null || sleep 1
 done
 rm -f "$candidate"
}
account_reserve() {
 local section="$1" user limit key lock now item state session assigned count=0 hash expiry device address seen='' signature
 config_get user "$section" username ''
 config_get limit "$section" max_sessions 0
 valid_range "$limit" 0 32 || return 1
 [ "$limit" -gt 0 ] || return 0
 key="$(printf '%s' "${user%@campus}" | sha256sum | awk '{print $1}')"
 lock="$STATE_DIR/account-$key.pid"
 account_lock_acquire "$lock" || return 1
 now="$(date +%s)"
 for item in $UPLINK_SECTIONS; do
  [ "$item" != "$UPLINK_ID" ] || continue
  assigned="$(json_file_value "$STATE_DIR/uplink-$item.json" '@.account')"
  state="$(json_file_value "$STATE_DIR/uplink-$item.json" '@.state')"
  session="$(json_file_value "$STATE_DIR/uplink-$item.json" '@.session')"
  device="$(json_file_value "$STATE_DIR/uplink-$item.json" '@.device')"; address="$(json_file_value "$STATE_DIR/uplink-$item.json" '@.ipv4')"
  signature="$device:$address"
  if account_session_active "$state" "$session";then
   if [ -n "$assigned" ] && [ "${assigned%@campus}" = "${user%@campus}" ]; then
    case "|$seen|" in *"|$signature|"*) ;; *) count=$((count+1)); seen="$seen|$signature";; esac
    continue
   fi
  fi
  hash=''; expiry=0
  [ ! -r "$STATE_DIR/reservation-$item" ] || read -r hash expiry <"$STATE_DIR/reservation-$item"
  if [ "$hash" = "$key" ] && is_uint "$expiry" && [ "$expiry" -gt "$now" ]; then count=$((count+1)); fi
 done
 if [ "$count" -ge "$limit" ]; then rm -f "$lock"; return 1; fi
 printf '%s %s\n' "$key" "$((now+120))" >"$STATE_DIR/reservation-$UPLINK_ID.$$" && mv -f "$STATE_DIR/reservation-$UPLINK_ID.$$" "$STATE_DIR/reservation-$UPLINK_ID" || { rm -f "$lock" "$STATE_DIR/reservation-$UPLINK_ID.$$";return 1; }
 rm -f "$lock"
}

account_release() { rm -f "$STATE_DIR/reservation-$UPLINK_ID"; }

account_credentials_signature() {
 printf '%s\n' "$1" "$2" "$3" "${DEVICE:-}" "${DEVICE6:-}" "${LOCAL_IPV4:-}" "${LOCAL_IPV6:-}" "${SSID:-}" "${BSSID:-}" | sha256sum | awk '{print $1}'
}
account_clear_rejection() { rm -f "$STATE_DIR/rejected-$UPLINK_ID-$1"; }
account_rejection_active() {
 local file="$STATE_DIR/rejected-$UPLINK_ID-$1" expiry signature now
 [ -s "$file" ] || return 1
 read -r expiry signature <"$file" || return 1
 now="$(date +%s)"
 if ! is_uint "$expiry" || [ "$expiry" -le "$now" ] || [ "$((expiry-now))" -gt 86400 ] ||
  [ "$signature" != "$(account_credentials_signature "$2" "$3" "$4")" ];then account_clear_rejection "$1";return 1;fi
 REJECTION_WAIT=$((expiry-now))
 return 0
}
account_reject() {
 local file="$STATE_DIR/rejected-$UPLINK_ID-$1" signature
 signature="$(account_credentials_signature "$2" "$3" "$4")" || return 1
 printf '%s %s\n' "$(($(date +%s)+CFG_CREDENTIAL_COOLDOWN))" "$signature" >"$file.$$" && mv -f "$file.$$" "$file"
}
