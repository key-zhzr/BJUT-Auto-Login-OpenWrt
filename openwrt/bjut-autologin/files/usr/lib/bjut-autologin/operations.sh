#!/bin/sh
# SPDX-License-Identifier: MIT
# One retained operation per uplink. Queue files contain no credentials.
operation_update() (
 local state="$1" phase="$2" file="$STATE_DIR/operation-$UPLINK_ID.json" id action account created deadline now
 [ -s "$file" ] || return 0
 id="$(json_file_value "$file" '@.id')"
 [ -n "${OPERATION_ID:-}" ] && [ "$id" = "$OPERATION_ID" ] || return 0
 action="$(json_file_value "$file" '@.action')"; account="$(json_file_value "$file" '@.account')"
 created="$(json_file_value "$file" '@.created_at')"; deadline="$(json_file_value "$file" '@.deadline')"; now="$(date +%s)"
 . "$JSHN_SH"; json_init
 json_add_string id "$id"; json_add_string action "$action"; json_add_string account "$account"
 json_add_string state "$state"; json_add_string phase "$phase"
 json_add_int created_at "$created"; json_add_int updated_at "$now"; json_add_int deadline "$deadline"
 json_add_int duration "$((now-created))"
 json_dump >"$file.$$" && mv -f "$file.$$" "$file"
)

operation_complete() {
 local state="$1" message="$2"
 case "$state" in online|authenticated_limited|logged_out) operation_update succeeded "$message";;
  login_accepted) operation_update verifying "$message";;
  busy|offline_suspected) operation_update running "$message";;
  *) operation_update failed "$message";;
 esac
}

operation_queue() {
 local action="$1" account="$2" file="$STATE_DIR/operation-$UPLINK_ID.json" now current deadline previous existing_account id owner
 now="$(date +%s)"
 if ! mkdir "$STATE_DIR/queue-$UPLINK_ID.lock" 2>/dev/null; then
  owner="$(cat "$STATE_DIR/queue-$UPLINK_ID.lock/pid" 2>/dev/null)"
  if ! is_uint "$owner" || kill -0 "$owner" 2>/dev/null;then reply error '该上游正在接收另一项操作，请稍后重试'; return;fi
  rm -rf "$STATE_DIR/queue-$UPLINK_ID.lock"
  mkdir "$STATE_DIR/queue-$UPLINK_ID.lock" 2>/dev/null || { reply error '该上游正在接收另一项操作，请稍后重试';return; }
 fi
 printf '%s' "$$" >"$STATE_DIR/queue-$UPLINK_ID.lock/pid"
 current="$(json_file_value "$file" '@.state')"; deadline="$(json_file_value "$file" '@.deadline')"
 case "$current" in queued|running|verifying)
  owner="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if is_uint "$deadline" && [ "$deadline" -le "$now" ] && is_uint "$owner" && kill -0 "$owner" 2>/dev/null; then
   rm -rf "$STATE_DIR/queue-$UPLINK_ID.lock"; reply error '上次操作仍在收尾，请等待接口检查结束'; return
  fi
  if is_uint "$deadline" && [ "$deadline" -gt "$now" ]; then
   previous="$(json_file_value "$file" '@.action')"; existing_account="$(json_file_value "$file" '@.account')"
   rm -rf "$STATE_DIR/queue-$UPLINK_ID.lock"
   if [ "$previous" = "$action" ] && [ "$existing_account" = "$account" ]; then
    . "$JSHN_SH"; json_init; json_add_string state loading; json_add_string message '相同操作已在处理中'
    json_add_string operationId "$(json_file_value "$file" '@.id')"; json_dump
   else reply error '该上游已有操作正在处理，请等待完成'; fi
   return
  fi;;
 esac
 id="$(random_ticket)"
 if ! valid_ticket "$id"; then rm -rf "$STATE_DIR/queue-$UPLINK_ID.lock"; reply error '无法创建操作，请更新路由端'; return; fi
 . "$JSHN_SH"; json_init
 json_add_string id "$id"; json_add_string action "$action"; json_add_string account "$account"
 json_add_string state queued; json_add_string phase '操作已排队'
 json_add_int created_at "$now"; json_add_int updated_at "$now"; json_add_int deadline "$((now+120))"; json_add_int duration 0
 json_dump >"$file.$$" && mv -f "$file.$$" "$file" || { rm -rf "$STATE_DIR/queue-$UPLINK_ID.lock"; reply error '操作未排队，请重试'; return; }
 printf '%s\n%s\n%s\n' "$action" "$account" "$id" >"$STATE_DIR/manual-$UPLINK_ID.$$" && mv -f "$STATE_DIR/manual-$UPLINK_ID.$$" "$STATE_DIR/manual-$UPLINK_ID"
 rm -rf "$STATE_DIR/queue-$UPLINK_ID.lock"
 /bin/sh "$SELF_BIN" manual "$UPLINK_ID" "$account" </dev/null >/dev/null 2>&1 &
 json_init; json_add_string state loading; json_add_string message '操作已排队，正在处理所选接口'; json_add_string operationId "$id"; json_dump
}

operation_status() {
 local file="$STATE_DIR/operation-$1.json" state deadline now
 [ -s "$file" ] || { printf '{}'; return; }
 state="$(json_file_value "$file" '@.state')"; deadline="$(json_file_value "$file" '@.deadline')"; now="$(date +%s)"
 case "$state" in queued|running|verifying)
  if is_uint "$deadline" && [ "$now" -ge "$deadline" ]; then
   # A timed-out view never repeats an authentication request automatically.
   . "$JSHN_SH"; json_load "$(cat "$file")" || return 1
   json_add_string state timeout; json_add_string phase '操作等待超时，请刷新状态后再决定是否重试'
   json_dump; return
  fi;;
 esac
 cat "$file"
}
