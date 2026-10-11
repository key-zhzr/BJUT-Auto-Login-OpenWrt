#!/bin/sh
# SPDX-License-Identifier: MIT
# Source rules only cover selected uplink addresses. LAN policies are preserved.

mwan_uci() {
 "$UCI_BIN" -q -c "$MWAN_STAGE" "$@"
}

mwan_begin() {
 local pid attempts=0
 MWAN_ORIGINAL="${BJUT_MWAN_CONFIG:-/etc/config/mwan3}"
 [ -r "$MWAN_ORIGINAL" ] || return 1
 # Do not apply another administrator's pending LuCI changes.
 [ -z "$("$UCI_BIN" -q changes mwan3 2>/dev/null)" ] || return 1
 mkdir -p "$STATE_DIR"
 if ! mkdir "$STATE_DIR/mwan-lock" 2>/dev/null; then
  pid="$(cat "$STATE_DIR/mwan-lock/pid" 2>/dev/null)"
  if is_uint "$pid" && kill -0 "$pid" 2>/dev/null; then
   while [ -d "$STATE_DIR/mwan-lock" ] && [ "$attempts" -lt 5 ]; do sleep 1; attempts=$((attempts + 1)); done
   [ ! -d "$STATE_DIR/mwan-lock" ] || return 1
  else rm -rf "$STATE_DIR/mwan-lock"; fi
  mkdir "$STATE_DIR/mwan-lock" 2>/dev/null || return 1
 fi
 printf '%s\n' "$$" >"$STATE_DIR/mwan-lock/pid"
 MWAN_STAGE="$(mktemp -d "$STATE_DIR/mwan.XXXXXX")" || { rm -rf "$STATE_DIR/mwan-lock"; return 1; }
 MWAN_PACKAGE="bjut_mwan_$(dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
 cp "$MWAN_ORIGINAL" "$MWAN_STAGE/$MWAN_PACKAGE" && cp "$MWAN_ORIGINAL" "$MWAN_STAGE/original" || { rm -rf -- "$MWAN_STAGE" "$STATE_DIR/mwan-lock"; return 1; }
 MWAN_CHANGED=0
}

mwan_finish() {
 local result="${1:-0}" newfile
 if [ "$result" = 0 ] && [ "$MWAN_CHANGED" = 1 ]; then
  mwan_uci commit "$MWAN_PACKAGE" && mwan_uci export "$MWAN_PACKAGE" >/dev/null || result=1
  if [ "$result" = 0 ] && cmp -s "$MWAN_STAGE/original" "$MWAN_ORIGINAL" && [ -z "$("$UCI_BIN" -q changes mwan3 2>/dev/null)" ]; then
   newfile="$(mktemp "$MWAN_ORIGINAL.bjut.XXXXXX")" || result=1
   [ "$result" != 0 ] || { cp -p "$MWAN_ORIGINAL" "$newfile" && cat "$MWAN_STAGE/$MWAN_PACKAGE" >"$newfile" && mv -f "$newfile" "$MWAN_ORIGINAL"; } || result=1
   [ -z "$newfile" ] || rm -f "$newfile"
   # Refresh only the user-rule chain. Do not restart mwan3 or disrupt healthy WANs.
   if [ "$result" = 0 ] && [ -d "${BJUT_MWAN_STATUS_DIR:-/var/run/mwan3}" ] && [ -r "${BJUT_MWAN_LIB:-/lib/mwan3/mwan3.sh}" ]; then
    ( . "$FUNCTIONS_SH"; . "${BJUT_NETWORK_LIB:-/lib/functions/network.sh}"; . "${BJUT_MWAN_LIB:-/lib/mwan3/mwan3.sh}"; mwan3_init; mwan3_set_user_rules ) >/dev/null 2>&1 || result=1
   fi
  else result=1; fi
 fi
 mwan_uci revert "$MWAN_PACKAGE" >/dev/null 2>&1 || true
 rm -rf -- "$MWAN_STAGE" "$STATE_DIR/mwan-lock"
 return "$result"
}

sync_mwan_rule() {
 local family="$1" source="$2" suffix name owner current existing_id
 suffix="$(printf '%s' "$UPLINK_ID" | "$CODEC_BIN" id32)" || return 1
 is_uint "$suffix" || return 1
 name="bjut_${suffix}_${family}"
 owner="$(mwan_uci get "$MWAN_PACKAGE.$name.bjut_managed")"
 if [ "$(mwan_uci get "$MWAN_PACKAGE.$name")" = rule ] && [ "$owner" != 1 ]; then return 1; fi
 existing_id="$(mwan_uci get "$MWAN_PACKAGE.$name.bjut_uplink")"
 [ -z "$existing_id" ] || [ "$existing_id" = "$UPLINK_ID" ] || return 1
 if [ -z "$source" ]; then
  [ "$owner" != 1 ] || { mwan_uci delete "$MWAN_PACKAGE.$name"; MWAN_CHANGED=1; }
  return 0
 fi
 [ "$family" != 6 ] || source="$source/128"
 [ "$family" != 4 ] || source="$source/32"
 current="$(mwan_uci get "$MWAN_PACKAGE.$name.src_ip")"
 if [ "$current" = "$source" ] && [ "$owner" = 1 ] && [ "$(mwan_uci get "$MWAN_PACKAGE.$name.use_policy")" = default ] && [ "$(mwan_uci get "$MWAN_PACKAGE.$name.bjut_uplink")" = "$UPLINK_ID" ]; then return 0; fi
 mwan_uci set "$MWAN_PACKAGE.$name=rule" &&
 mwan_uci set "$MWAN_PACKAGE.$name.bjut_managed=1" &&
 mwan_uci set "$MWAN_PACKAGE.$name.bjut_uplink=$UPLINK_ID" &&
 mwan_uci set "$MWAN_PACKAGE.$name.family=ipv$family" &&
 mwan_uci set "$MWAN_PACKAGE.$name.src_ip=$source" &&
 mwan_uci set "$MWAN_PACKAGE.$name.proto=all" &&
 mwan_uci set "$MWAN_PACKAGE.$name.use_policy=default" &&
 mwan_uci set "$MWAN_PACKAGE.$name.sticky=0" &&
 mwan_uci reorder "$MWAN_PACKAGE.$name=0" || return 1
 MWAN_CHANGED=1
}

sync_mwan_rules() {
 local result=0
 [ "$CFG_MWAN3" = 1 ] && [ -r "${BJUT_MWAN_CONFIG:-/etc/config/mwan3}" ] || return 0
 mwan_begin || return 1
 sync_mwan_rule 4 "$LOCAL_IPV4" || result=1
 sync_mwan_rule 6 "$LOCAL_IPV6" || result=1
 mwan_finish "$result"
}

prune_mwan_rules() {
 local signature previous section owner id keep
 [ -r "${BJUT_MWAN_CONFIG:-/etc/config/mwan3}" ] || return 0
 signature="id32:$CFG_MWAN3:$UPLINK_SECTIONS"
 previous="$(cat "$STATE_DIR/mwan-config" 2>/dev/null)"
 [ "$signature" != "$previous" ] || return 0
 mwan_begin || return 1
 for section in $(mwan_uci show "$MWAN_PACKAGE" | sed -n "s/^$MWAN_PACKAGE\.\([A-Za-z0-9_]*\)=rule$/\1/p"); do
  owner="$(mwan_uci get "$MWAN_PACKAGE.$section.bjut_managed")"
  [ "$owner" = 1 ] || continue
  id="$(mwan_uci get "$MWAN_PACKAGE.$section.bjut_uplink")"
  keep=0
  if [ "$CFG_MWAN3" = 1 ] && valid_section "$id"; then
   case " $UPLINK_SECTIONS " in *" $id "*)
    expected="$(printf '%s' "$id" | "$CODEC_BIN" id32)" || { mwan_finish 1; return 1; }
    case "$section" in "bjut_${expected}_4"|"bjut_${expected}_6") keep=1 ;; esac ;;
   esac
  fi
  [ "$keep" = 1 ] || { mwan_uci delete "$MWAN_PACKAGE.$section"; MWAN_CHANGED=1; }
 done
 mwan_finish || return 1
 printf '%s' "$signature" >"$STATE_DIR/mwan-config"
}
