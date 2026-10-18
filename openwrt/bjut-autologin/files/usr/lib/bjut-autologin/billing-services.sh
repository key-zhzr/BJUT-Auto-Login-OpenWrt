#!/bin/sh
# SPDX-License-Identifier: MIT
# Named, account-scoped billing modules. Never accept an endpoint from a caller.
billing_saved_extract() { "${BJUT_HTML:-/usr/libexec/bjut-html}" "$2" "${3:-}" <"$BILLING_JOB/$1.html"; }
billing_page() {
 local key="$1" path="$2"
 billing_request "$path" || return 1
 cp "$WORK_DIR/billing-body" "$BILLING_JOB/$key.html"
}
billing_choices() {
 local file="$1" operation="$2" id label tab
 tab="$(printf '\t')"
 json_add_array "$3"
 if [ -s "$BILLING_JOB/$file.html" ]; then
  billing_saved_extract "$file" "$operation" >"$WORK_DIR/choices"
  while IFS="$tab" read -r id label; do
   [ -n "$id" ] || continue
   json_add_object ''; json_add_string id "$id"; json_add_string name "$label"; json_close_object
  done <"$WORK_DIR/choices"
 fi
 json_close_array
}
billing_table() {
 local name="$1" file="$2" fields="$3" prefix='@' index=0 column value row
 json_add_object "$name"; json_add_array columns
 for column in $fields; do json_add_string '' "$column"; done; json_close_array
 json_add_array rows
 if [ -s "$file" ]; then
  [ -z "$(json_file_value "$file" '@.rows')" ] || prefix='@.rows'
  [ -z "$(json_file_value "$file" '@.data')" ] || prefix='@.data'
  while [ "$index" -lt 100 ]; do
   row="$(json_file_value "$file" "$prefix[$index]")"; [ -n "$row" ] || break
   json_add_array ''; column=0
   for key in $fields; do
    value="$(printf '%s' "$row" | "$JSONFILTER_BIN" -e "@.$key" 2>/dev/null)"
    [ -n "$value" ] || value="$(printf '%s' "$row" | "$JSONFILTER_BIN" -e "@[$column]" 2>/dev/null)"
    [ "${#value}" -le 256 ] || value=''
    json_add_string '' "$value"; column=$((column+1))
   done
   json_close_array; index=$((index+1))
  done
 fi
 json_close_array; json_close_object
}
billing_module() {
 local module="$1" user value key can_stop=0 can_reopen=0 can_cancel=0 mauth='' policy flag reason
 user="$(billing_saved_extract dashboard user-json)"
 billing_progress loading 60 '正在读取计费模块'
 BILLING_REFERER=https://jfself.bjut.edu.cn/Self/dashboard; BILLING_AJAX=1
 case "$module" in
  services)
   billing_page stop /Self/service/goStop || true
   billing_page reopen /Self/service/goReopen || true
   billing_page package /Self/service/package || true
   billing_page protect /Self/service/consumeProtect || true
   if [ "$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.useFlag')" = 1 ] && billing_saved_extract stop enabled stopNow; then can_stop=1; fi
   flag="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.useFlag')";reason="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.stopReason')"
   if { [ "$flag" = 0 ] || [ -n "$reason" ]; } && billing_saved_extract reopen enabled reOpenNow; then can_reopen=1; fi
   if billing_reservation package;then can_cancel=1;fi
   json_init; json_add_int canStop "$can_stop";json_add_int canReopen "$can_reopen";json_add_int canCancel "$can_cancel";json_add_string scheduledPackage "${BILLING_SCHEDULED:-}"
   json_add_int available "$( if [ -s "$BILLING_JOB/package.html" ] || [ -s "$BILLING_JOB/stop.html" ];then printf 1;else printf 0;fi )"
   for key in installmentFlag useMoney; do
    value="$(billing_saved_extract protect user-json | "$JSONFILTER_BIN" -e "@.$key" 2>/dev/null)"
    [ -n "$value" ] || value="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e "@.$key" 2>/dev/null)"
    json_add_string "$key" "$value"
   done
   value="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.serviceDefault.defaultName')";json_add_string currentPackage "$value"
   billing_choices package packages packages
   ;;
  devices)
   billing_page mac /Self/service/myMac || true
   billing_request '/Self/service/getMacList?pageSize=100&pageNumber=1&sortName=2&sortOrder=DESC' && cp "$WORK_DIR/billing-body" "$BILLING_JOB/macs.json"
   billing_request /Self/dashboard/getOnlineList && cp "$WORK_DIR/billing-body" "$BILLING_JOB/online.json"
   if billing_request /Self/dashboard/refreshMauthType; then mauth="$(billing_extract mauth)"; fi
   json_init;json_add_string mauth "$mauth"
   billing_table macs "$BILLING_JOB/macs.json" 'online mac device lastLoginAt lastIp'
   ;;
  security)
   billing_page password /Self/setting/changePassword || true
   billing_page questions /Self/setting/passwordQuestion || true
   json_init; billing_choices questions questions questions
   policy="$(billing_saved_extract password object passwordPolicy)"
   for key in FLDMINLENGTH FLDREQUIREUPPER FLDREQUIRELOWER FLDREQUIREDIGIT FLDREQUIRESPECIAL; do
    value="$(printf '%s' "$policy" | "$JSONFILTER_BIN" -e "@.$key" 2>/dev/null)"; is_uint "$value" || value=0
    json_add_int "$key" "$value"
   done
   ;;
  history)
   billing_request /Self/dashboard/getLoginHistory && cp "$WORK_DIR/billing-body" "$BILLING_JOB/history.json"
   json_init;billing_table history "$BILLING_JOB/history.json" 'loginTime logoutTime ip ipv6 mac durationMinutes flowMb billingMode amount'
   ;;
  *) return 1;;
 esac
 json_add_string state ready;json_add_string account "$BILLING_ACCOUNT";json_add_string module "$module";json_add_int percent 100;json_add_string message '计费数据已更新'
 json_dump >"$BILLING_JOB/result.json.$$" && mv -f "$BILLING_JOB/result.json.$$" "$BILLING_JOB/result.json"
}
billing_ajax_token() {
 local token path
 token="$(billing_saved_extract dashboard literal ajaxCsrfToken)"
 [ -n "$token" ] || token="$(billing_saved_extract dashboard literal AJAXCSRFTOKEN)"
 if [ -z "$token" ]; then
  billing_saved_extract dashboard assets >"$WORK_DIR/dashboard-assets"
  while IFS= read -r path; do
   case "$path" in /Self/*.js|/Self/*.js\?*) ;; *) continue;; esac
   billing_request "$path" || continue
   token="$(billing_extract literal ajaxCsrfToken)"; [ -n "$token" ] || token="$(billing_extract literal AJAXCSRFTOKEN)"
   [ -z "$token" ] || break
  done <"$WORK_DIR/dashboard-assets"
 fi
 [ -n "$token" ] || return 1
 printf '%s' "$token"
}
billing_action_value() { json_file_value "$BILLING_JOB/action.json" "@.$1"; }
billing_form_value() {
 local value="$1"
 [ -n "$value" ] && [ "${#value}" -le 256 ] && ! printf '%s' "$value" | LC_ALL=C grep -q '[^A-Za-z0-9_.-]'
}
billing_mac() { printf '%s' "$1" | tr -d ':.-' | tr 'A-F' 'a-f'; }
billing_apply_action() {
 local action="$1" page path='' data='' token='' csrf='' key value mac old new user current requested index expected exists=0 response message='操作已完成'
 user="$(billing_saved_extract dashboard user-json)"
 BILLING_AJAX=1
 billing_progress loading 65 '正在核对并提交计费操作'
 case "$action" in
  stopNow|reopenNow)
   if [ "$action" = stopNow ]; then page=/Self/service/goStop;path=/Self/service/stop;key=stopNow;expected=1;else page=/Self/service/goReopen;path=/Self/service/reOpen;key=reOpenNow;expected=0;fi
   [ "$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.useFlag')" = "$expected" ] || { [ "$action" = reopenNow ] && [ -n "$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.stopReason')" ]; } || { billing_progress error 100 '账号状态已变化，请刷新后重试';return 1; }
   billing_page operation "$page" && billing_saved_extract operation enabled "$key" || { billing_progress error 100 '计费系统当前未开放此操作';return 1; }
   token="$(billing_ajax_token)" || return 1;data="flag=1&ajaxCsrfToken=$(urlencode "$token")";;
  schedulePackage|cancelPackage)
   page=/Self/service/package;billing_page operation "$page" || return 1
   if [ "$action" = schedulePackage ];then
    value="$(billing_action_value packageId)";billing_form_value "$value" || return 1
    billing_saved_extract operation packages >"$WORK_DIR/allowed-packages"
    awk -F '\t' -v wanted="$value" '$1==wanted {found=1} END{exit !found}' "$WORK_DIR/allowed-packages" || { billing_progress error 100 '套餐列表已变化，请刷新后重试';return 1; }
    csrf="$(billing_saved_extract operation package-csrf)";[ -n "$csrf" ] || csrf="$(billing_saved_extract operation input csrftoken)"
    billing_form_value "$csrf" || return 1
    path=/Self/service/doPackage;data="csrftoken=$(urlencode "$csrf")&serid=$(urlencode "$value")"
   else
    billing_reservation operation || { billing_progress error 100 '当前没有可取消的套餐预约';return 1; }
    token="$(billing_ajax_token)" || return 1;path=/Self/service/undoPackage;data="ajaxCsrfToken=$(urlencode "$token")"
   fi;;
  setConsumeLimit)
   page=/Self/service/consumeProtect;billing_page operation "$page" || return 1
   value="$(billing_action_value consumeLimit)"
   printf '%s' "$value" | grep -Eq '^[0-9]{1,6}([.][0-9]{1,2})?$' || return 1
   current="$(billing_saved_extract operation user-json | "$JSONFILTER_BIN" -e '@.useMoney')"
   awk -v wanted="$value" -v spent="$current" 'BEGIN{exit !(wanted==999999 || wanted+0>=spent+0)}' || { billing_progress error 100 '消费限额不能低于本周期消费';return 1; }
   csrf="$(billing_saved_extract operation input csrftoken)";billing_form_value "$csrf" || return 1
   path=/Self/service/changeConsumeProtect;data="csrftoken=$(urlencode "$csrf")&consumeLimit=$(urlencode "$value")";;
  bindMac|unbindMac)
   page=/Self/service/myMac;billing_page operation "$page" || return 1
   mac="$(billing_mac "$(billing_action_value mac)")";[ "${#mac}" = 12 ] || return 1
   case "$mac" in *[!0-9a-f]*)return 1;;esac
   token="$(billing_ajax_token)" || return 1
   if [ "$action" = bindMac ];then path=/Self/service/bindMac;data="macAddress=$mac&macType=0&ajaxCsrfToken=$(urlencode "$token")"
   else
    billing_request '/Self/service/getMacList?pageSize=100&pageNumber=1&sortName=2&sortOrder=DESC' || return 1
    cp "$WORK_DIR/billing-body" "$WORK_DIR/mac-before.json";billing_mac_in_file "$WORK_DIR/mac-before.json" "$mac" || { billing_progress error 100 '设备列表已变化，请刷新后重试';return 1; }
    path="/Self/service/unbindmac?mac=$mac&ajaxCsrfToken=$(urlencode "$token")&t=$(date +%s)"
   fi;;
  disconnectSession)
   page=/Self/dashboard;token="$(billing_ajax_token)" || return 1
   index="$(billing_action_value sessionIndex)";is_uint "$index" && [ "$index" -lt 100 ] || return 1
   current="$(billing_rows_prefix "$BILLING_JOB/selected-online.json")"
   old="$(json_file_value "$BILLING_JOB/selected-online.json" "$current[$index].sessionId")";value="$(json_file_value "$BILLING_JOB/selected-online.json" "$current[$index].ip")";mac="$(billing_mac "$(json_file_value "$BILLING_JOB/selected-online.json" "$current[$index].mac")")"
   [ -n "$old" ] && [ "${#old}" -le 512 ] && [ -n "$value" ] && [ "${#value}" -le 64 ] || return 1
   billing_request /Self/dashboard/getOnlineList || return 1
   cp "$WORK_DIR/billing-body" "$WORK_DIR/session-before.json"
   billing_session_exists "$WORK_DIR/session-before.json" "$old" "$value" "$mac" || { billing_progress error 100 '在线会话已变化，请刷新后重试';return 1; }
   path="/Self/dashboard/tooffline?sessionid=$(urlencode "$old")&ip=$(urlencode "$value")&mac=$(urlencode "$mac")&ajaxCsrfToken=$(urlencode "$token")&t=$(date +%s)";;
  setMauth)
   page=/Self/dashboard;requested="$(billing_action_value enabled)";case "$requested" in 0|1);;*)return 1;;esac
   billing_request /Self/dashboard/refreshMauthType || return 1;current="$(billing_extract mauth)";case "$current" in 0|1);;*)return 1;;esac
   if [ "$current" != "$requested" ];then billing_request "/Self/dashboard/oprateMauthAction?t=$(date +%s)" || return 1;fi
   billing_request /Self/dashboard/refreshMauthType || return 1
   [ "$(billing_extract mauth)" = "$requested" ] || { billing_progress error 100 '计费系统未确认无感认证状态';return 1; }
   billing_progress ready 100 '无感认证状态已更新';return 0;;
  changePassword|updateQuestions)
   old="$(billing_action_value oldPassword)";[ -n "$old" ] && [ "${#old}" -le 4096 ] || return 1
   # The current password is checked by the billing server; it is never logged.
   if [ "$action" = changePassword ];then
    page=/Self/setting/changePassword;path=/Self/setting/changePasswordMethod
    billing_page operation "$page" || return 1;new="$(billing_action_value newPassword)"
    [ "$new" != "$old" ] && billing_password_valid "$new" || { billing_progress error 100 '新密码不符合页面要求';return 1; }
    data="oldPassword=$(urlencode "$old")&newPassword=$(urlencode "$new")&confirmPassword=$(urlencode "$new")"
   else
    page=/Self/setting/passwordQuestion;path=/Self/setting/updatePasswordQuestion;billing_page operation "$page" || return 1
    billing_saved_extract operation questions >"$WORK_DIR/allowed-questions";data="password=$(urlencode "$old")";current='|'
    for index in 1 2 3;do
     key="$(billing_action_value "question$index")";value="$(billing_action_value "answer$index")"
     [ -n "$value" ] && [ "$(printf '%s' "$value" | wc -m | tr -d ' ')" -le 16 ] || return 1
     case "$current" in *"|$key|"*)return 1;;esac;current="$current$key|"
     awk -F '\t' -v wanted="$key" '$1==wanted{found=1} END{exit !found}' "$WORK_DIR/allowed-questions" || return 1
     data="$data&question$index=$(urlencode "$key")&answer$index=$(urlencode "$value")"
    done
   fi
   csrf="$(billing_saved_extract operation input csrftoken)";billing_form_value "$csrf" || return 1
   data="$data&csrftoken=$(urlencode "$csrf")";old='';;
  *)return 1;;
 esac
 BILLING_REFERER="https://jfself.bjut.edu.cn$page"
 billing_request "$path" "$data" || { billing_progress error 100 '操作响应未确认，请刷新状态后再操作';return 1; }
 data='';token='';csrf=''
 if [ "$action" = unbindMac ];then
  billing_request '/Self/service/getMacList?pageSize=100&pageNumber=1&sortName=2&sortOrder=DESC' || return 1
  cp "$WORK_DIR/billing-body" "$WORK_DIR/mac-after.json"
  ! billing_mac_in_file "$WORK_DIR/mac-after.json" "$mac" || return 1
 else
  response="$(json_file_value "$WORK_DIR/billing-body" '@.state')";value="$(json_file_value "$WORK_DIR/billing-body" '@.success')"
  [ "$response" = success ] || [ "$value" = true ] || { billing_progress error 100 '计费系统未确认操作成功，请刷新后检查';return 1; }
 fi
 if [ "$action" = changePassword ];then billing_update_saved_password "$new";message='密码已修改，请核对账号管理中的保存密码';fi
 billing_progress ready 100 "$message";log_message info "计费操作已完成：$action"
}
billing_rows_prefix() {
 local file="$1" prefix='@'
 [ -z "$(json_file_value "$file" '@.rows')" ] || prefix='@.rows'
 [ -z "$(json_file_value "$file" '@.data')" ] || prefix='@.data'
 printf '%s' "$prefix"
}
billing_mac_in_file() {
 local file="$1" wanted="$2" prefix index=0 value
 prefix="$(billing_rows_prefix "$file")"
 while [ "$index" -lt 100 ];do
  value="$(json_file_value "$file" "$prefix[$index].mac")";[ -n "$value" ] || value="$(json_file_value "$file" "$prefix[$index][1]")"
  [ -n "$value" ] || break
  [ "$(billing_mac "$value")" != "$wanted" ] || return 0
  index=$((index+1))
 done
 return 1
}
billing_session_exists() {
 local file="$1" sid="$2" ip="$3" mac="$4" prefix index=0 value
 prefix="$(billing_rows_prefix "$file")"
 while [ "$index" -lt 100 ];do
  value="$(json_file_value "$file" "$prefix[$index].sessionId")";[ -n "$value" ] || break
  if [ "$value" = "$sid" ] && [ "$(json_file_value "$file" "$prefix[$index].ip")" = "$ip" ] && [ "$(billing_mac "$(json_file_value "$file" "$prefix[$index].mac")")" = "$mac" ];then return 0;fi
  index=$((index+1))
 done
 return 1
}
billing_password_valid() {
 local value="$1" length min policy key flag
 length="$(printf '%s' "$value" | wc -m | tr -d ' ')";policy="$(billing_saved_extract operation object passwordPolicy)"
 min="$(printf '%s' "$policy" | "$JSONFILTER_BIN" -e '@.FLDMINLENGTH')";is_uint "$min" && [ "$min" -gt 0 ] || min=8
 [ "$length" -ge "$min" ] && [ "$length" -le 16 ] || return 1
 ! printf '%s' "$value" | grep -q '[[:space:]]' || return 1
 for key in FLDREQUIREUPPER FLDREQUIRELOWER FLDREQUIREDIGIT FLDREQUIRESPECIAL;do
  flag="$(printf '%s' "$policy" | "$JSONFILTER_BIN" -e "@.$key")";[ "$flag" = 1 ] || continue
  case "$key" in FLDREQUIREUPPER) printf '%s' "$value" | grep -q '[A-Z]';;FLDREQUIRELOWER) printf '%s' "$value" | grep -q '[a-z]';;FLDREQUIREDIGIT) printf '%s' "$value" | grep -q '[0-9]';;*)printf '%s' "$value" | grep -q '[!@#$%^&*()]';;esac || return 1
 done
}
billing_update_saved_password() {
 local new="$1" section user
 # Update all local entries for this verified billing account via UCI stdin.
 # A failed local save must not turn a successful remote password change into
 # a retry of the old password-changing request.
 configuration_lock || return 0
 for section in $ACCOUNT_SECTIONS;do
  config_get user "$section" username '';[ "$user" = "$BILLING_ACCOUNT" ] || continue
  { printf 'set bjut-autologin.%s.password=' "$section";uci_quote "$new";printf '\ncommit bjut-autologin\n'; } | "$UCI_BIN" -q batch >/dev/null 2>&1 || true
 done
 configuration_unlock
}

billing_validate_payload() {
 local operation="$1" payload="$2" allowed keys key value type
 case "$operation" in
  stopNow|reopenNow|cancelPackage) allowed='';;
  schedulePackage) allowed='packageId';;
  setConsumeLimit) allowed='consumeLimit';;
  bindMac|unbindMac) allowed='mac';;
  disconnectSession) allowed='sessionIndex';;
  setMauth) allowed='enabled';;
  changePassword) allowed='oldPassword newPassword';;
  updateQuestions) allowed='oldPassword question1 question2 question3 answer1 answer2 answer3';;
  *)return 1;;
 esac
 [ "${#payload}" -le 16384 ] || return 1
 json_load "$payload" || return 1;json_get_keys keys
 for key in $keys;do
  case " $allowed " in *" $key "*);;*)return 1;;esac
  json_get_type type "$key";[ "$type" = string ] || return 1
  json_get_var value "$key"
  [ "${#value}" -le 4096 ] && ! printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]' || return 1
 done
 for key in $allowed;do case " $keys " in *" $key "*);;*)return 1;;esac;done
}

billing_reservation() {
 local page="$1" prefix row state current scheduled
 BILLING_SCHEDULED=''
 if billing_request '/Self/service/packageLog?pageSize=10&pageNumber=1&sortName=fldchangedate&sortOrder=DESC';then
  cp "$WORK_DIR/billing-body" "$WORK_DIR/reservation.json";prefix="$(billing_rows_prefix "$WORK_DIR/reservation.json")"
  row="$(json_file_value "$WORK_DIR/reservation.json" "$prefix[0]")"
  state="$(printf '%s' "$row" | "$JSONFILTER_BIN" -e '@.fldstate')";[ -n "$state" ] || state="$(printf '%s' "$row" | "$JSONFILTER_BIN" -e '@[4]')"
  if [ -n "$state" ];then
   [ "$state" = 1 ] || return 1
   current="$(printf '%s' "$row" | "$JSONFILTER_BIN" -e '@.flddefaultname1')";[ -n "$current" ] || current="$(printf '%s' "$row" | "$JSONFILTER_BIN" -e '@[2]')"
   scheduled="$(printf '%s' "$row" | "$JSONFILTER_BIN" -e '@.flddefaultname2')";[ -n "$scheduled" ] || scheduled="$(printf '%s' "$row" | "$JSONFILTER_BIN" -e '@[3]')"
   [ -n "$scheduled" ] && [ "${#scheduled}" -le 256 ] && [ "$scheduled" != "$current" ] || return 1
   BILLING_SCHEDULED="$scheduled";return 0
  fi
 fi
 billing_saved_extract "$page" package-cancel
}
