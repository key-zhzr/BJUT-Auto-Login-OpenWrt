#!/bin/sh
# SPDX-License-Identifier: MIT
billing_monitor_start() {
 local now due
 [ "${CFG_BILLING_BACKGROUND:-0}" = 1 ] || return 0
 valid_range "$CFG_BILLING_INTERVAL" 900 86400 || return 0
 now="$(date +%s)"; due="$(cat "$STATE_DIR/billing-monitor-next" 2>/dev/null)"
 is_uint "$due" && [ "$due" -gt "$now" ] && return 0
 printf '%s' "$((now+${CFG_BILLING_INTERVAL:-21600}))" >"$STATE_DIR/billing-monitor-next"
 /bin/sh "${BJUT_BILLING_MONITOR:-/usr/libexec/bjut-billing-monitor}" </dev/null >/dev/null 2>&1 &
}

billing_cached() (
 local section user key file comma='' error
 printf '{"items":['
 for section in $ACCOUNT_SECTIONS; do
  config_get user "$section" username ''
  key="$(printf '%s' "$user" | sha256sum | awk '{print $1}')"; file="$STATE_DIR/billing-latest/$key.json"
  error="$STATE_DIR/billing-latest/$key-error.json"
  [ -s "$file" ] || [ -s "$error" ] || continue
  . "$JSHN_SH"; json_init
  if [ -s "$file" ]; then json_load "$(cat "$file")" || continue; else json_add_string account "$user"; json_add_string state error; fi
  if [ -s "$error" ]; then json_add_string backgroundState "$(json_file_value "$error" '@.state')"; json_add_string backgroundMessage "$(json_file_value "$error" '@.message')"; fi
  printf '%s' "$comma"; comma=,; json_dump
 done
 printf ']}\n'
)

billing_monitor_run() {
 local section user enabled key uplink candidate assigned ticket now result balance flow alarm seen=''
 mkdir -p "$STATE_DIR/billing-latest" "$STATE_DIR/billing" || return 1
 for section in $ACCOUNT_SECTIONS; do
  config_get_bool enabled "$section" enabled 1; [ "$enabled" = 1 ] || continue
  config_get user "$section" username ''; [ -n "$user" ] || continue
  key="$(printf '%s' "$user" | sha256sum | awk '{print $1}')"
  case "|$seen|" in *"|$key|"*) continue;; esac; seen="$seen|$key"
  uplink=''
  # Prefer an already-authenticated source, then an explicitly assigned uplink.
  for candidate in $UPLINK_SECTIONS; do
   assigned="$(json_file_value "$STATE_DIR/uplink-$candidate.json" '@.account')"
   if [ "$assigned" = "$user" ]; then uplink="$candidate"; break; fi
  done
  if [ -z "$uplink" ]; then
   for candidate in $UPLINK_SECTIONS; do
    config_get assigned "$candidate" accounts ''
    case " $assigned " in *" $section "*|'  ') uplink="$candidate"; break;; esac
   done
  fi
  [ -n "$uplink" ] || continue
  key="$(printf '%s' "$user" | sha256sum | awk '{print $1}')"; ticket="$("$CODEC_BIN" random16)"
  case "$ticket" in ''|*[!0-9a-f]*) return 1;; esac; [ "${#ticket}" = 32 ] || return 1
  mkdir "$STATE_DIR/billing/$ticket" || return 1
  now="$(date +%s)"; printf '%s' "$now" >"$STATE_DIR/billing/$ticket/created"
  printf '%s' background | sha256sum | awk '{print $1}' >"$STATE_DIR/billing/$ticket/owner"
  . "$JSHN_SH"; json_init
  json_add_string uplink "$uplink"; json_add_string account "$section"; json_add_string action begin
  json_dump >"$STATE_DIR/billing/$ticket/request.json"
  /bin/sh "${BJUT_BILLING:-/usr/libexec/bjut-billing}" "$ticket"
  result="$STATE_DIR/billing/$ticket/result.json"
  if [ "$(json_file_value "$result" '@.state')" = ready ]; then
   cp "$result" "$STATE_DIR/billing-latest/$key.json.$$" && mv -f "$STATE_DIR/billing-latest/$key.json.$$" "$STATE_DIR/billing-latest/$key.json"
   rm -f "$STATE_DIR/billing-latest/$key-error.json"
   balance="$(json_file_value "$result" '@.balance')"; flow="$(json_file_value "$result" '@.remainingFlow')"
   alarm="$(awk -v b="$balance" -v f="$flow" -v bt="$CFG_BALANCE_THRESHOLD" -v ft="$CFG_FLOW_THRESHOLD" 'BEGIN{if(b!="" && b+0<=bt+0)printf "余额不足 ";if(f!="" && f+0<=ft*1024)printf "流量不足"}')"
   if [ -n "$alarm" ] && [ "$CFG_BILLING_ALERTS" = 1 ]; then
    pushplus_queue_custom ".billing-$key" '校园网用量提醒' "账号：${user}；${alarm}。余额：$(json_file_value "$result" '@.balanceText')；剩余流量：$(json_file_value "$result" '@.remainingFlowText')。"
   else
    # Invalidate delayed warnings after recovery or after alerts are disabled.
    rm -f "$STATE_DIR/pushplus/.billing-$key/pending.json" "$STATE_DIR/pushplus/.billing-$key/notified" "$STATE_DIR/pushplus/.billing-$key/state.json"
   fi
   log_message info "后台计费已更新：账号 $user"
  else
   . "$JSHN_SH"; json_init; json_add_string account "$user"; json_add_string state "$(json_file_value "$result" '@.state')"
   json_add_string message "$(json_file_value "$result" '@.message')"; json_add_int updatedAt "$now"
   json_dump >"$STATE_DIR/billing-latest/$key-error.json"
   log_message warning "后台计费未完成：账号 ${user}；请在计费中心核对"
  fi
  rm -rf "$STATE_DIR/billing/$ticket"
 done
}
