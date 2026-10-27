#!/bin/sh
# jfself online counters. Never substitute interface byte counters on failure.
# Match only observed upstream addresses/MACs; a billing query through an
# uplink does not make all devices in that account belong to that uplink.
traffic_identity_prepare() (
 local candidate mac ip device addresses
 for candidate in $UPLINK_SECTIONS;do
  (select_uplink "$candidate" && read_network_identity || exit 0
   for device in "$DEVICE" "$DEVICE6";do
    valid_device_name "$device" || continue
    mac="$(billing_mac "$(cat "$SYS_NET/$device/address" 2>/dev/null)")"
    addresses=''
    [ "$device" != "$DEVICE" ] || addresses="$LOCAL_IPV4"
    [ "$device" != "$DEVICE6" ] || addresses="$addresses $LOCAL_IPV6"
    for ip in $addresses $("$IP_BIN" -o addr show dev "$device" scope global 2>/dev/null | awk '{split($4,a,"/");print a[1]}');do
     ip="$(printf '%s' "$ip" | "$CODEC_BIN" normalize-ip 2>/dev/null)";[ -n "$ip" ] || continue
     printf 'interface:%s\t%s\t%s\t%s\n' "$device" "$device" "${mac:--}" "$ip"
    done
   done)
 done | sort -u >"$STATE_DIR/traffic-identities.tsv.$$.tmp"
 mv -f "$STATE_DIR/traffic-identities.tsv.$$.tmp" "$STATE_DIR/traffic-identities.tsv"
)
traffic_match_identity() {
 local mac="$1" ip ipv6 match id
 ip="$(printf '%s' "$2" | "$CODEC_BIN" normalize-ip 2>/dev/null)"
 ipv6="$(printf '%s' "$3" | "$CODEC_BIN" normalize-ip 2>/dev/null)"
 match="$(awk -F '\t' -v mac="$mac" -v ip="$ip" -v ipv6="$ipv6" '$3!="-" && mac!="" && $3==mac {matched=$1 "\t" $2 "\t1";exit} ip!="" && $4==ip {primary=$1 "\t" $2 "\t1"} ipv6!="" && $4==ipv6 {secondary=$1 "\t" $2 "\t1"} END{if(matched!="")print matched;else if(primary!="")print primary;else if(secondary!="")print secondary}' "$STATE_DIR/traffic-identities.tsv" 2>/dev/null)"
 if [ -n "$match" ];then printf '%s' "$match";else
  id="$(printf '%s' "${mac:-${ip:-$ipv6}}" | sha256sum | cut -c1-16)"
  printf 'device:%s\t%s\t0' "$id" "${mac:-${ip:-device}}"
 fi
}

traffic_schedule_next() {
 local next="$1"
 is_uint "$next" || return 0
 if ! is_uint "${TRAFFIC_NEXT_AT:-}" || [ "$next" -lt "$TRAFFIC_NEXT_AT" ];then
  TRAFFIC_NEXT_AT="$next"
 fi
}

# Select accounts before opening billing sessions. Unknown upstream identities
# wait for the authentication worker; never enumerate every stored credential.
traffic_active_prepare() {
 local candidate state account
 TRAFFIC_ACTIVE_ACCOUNTS=''
 [ "${CFG_TRAFFIC_SCOPE:-local}" = local ] || return 0
 for candidate in $UPLINK_SECTIONS;do
  state="$(json_file_value "$STATE_DIR/uplink-$candidate.json" '@.state')"
  case "$state" in online|authenticated_limited|login_accepted|probe_uncertain) ;;*)continue;;esac
  account="$(json_file_value "$STATE_DIR/uplink-$candidate.json" '@.account')";account="${account%@campus}"
  case "$account" in ''|*[!A-Za-z0-9_@.,-]*)continue;;esac
  case " $TRAFFIC_ACTIVE_ACCOUNTS " in *" $account "*) ;;*)TRAFFIC_ACTIVE_ACCOUNTS="$TRAFFIC_ACTIVE_ACCOUNTS $account";;esac
 done
}
traffic_account_selected() {
 [ "${CFG_TRAFFIC_SCOPE:-local}" = local ] || return 0
 case " $TRAFFIC_ACTIVE_ACCOUNTS " in *" ${1%@campus} "*)return 0;;*)return 1;;esac
}

traffic_candidates() {
 local user="$1" candidate state account rank
 for candidate in $UPLINK_SECTIONS;do
  state="$(json_file_value "$STATE_DIR/uplink-$candidate.json" '@.state')"
  account="$(json_file_value "$STATE_DIR/uplink-$candidate.json" '@.account')"
  rank=3
  case "$state" in online|authenticated_limited|login_accepted) rank=1;;esac
  if [ "${account%@campus}" = "${user%@campus}" ] && [ "$rank" = 1 ];then rank=0;fi
  printf '%s %s\n' "$rank" "$candidate"
 done | sort -n | awk '{print $2}'
}
traffic_collect() {
 local section user password key uplink ticket now result retry seen='' due started elapsed sampled previous candidates attempts message success finished
 [ "${CFG_TRAFFIC_MONITOR:-0}" = 1 ] || return 0
 TRAFFIC_NEXT_AT="$(($(date +%s)+60))"
 [ "${BJUT_TRAFFIC_IDENTITIES_READY:-0}" = 1 ] && [ -s "$STATE_DIR/traffic-identities.tsv" ] || traffic_identity_prepare
 mkdir -p "$STATE_DIR/traffic" "$STATE_DIR/billing" || return 1
 traffic_active_prepare
 for section in $ACCOUNT_SECTIONS;do
  [ -z "${TRAFFIC_ONLY_ACCOUNT:-}" ] || [ "$section" = "$TRAFFIC_ONLY_ACCOUNT" ] || continue
  config_get user "$section" username '';config_get password "$section" password ''
  [ -n "$user" ] && [ -n "$password" ] || continue
  traffic_account_selected "$user" || continue
  key="$(printf '%s' "$user" | sha256sum | awk '{print $1}')";password=''
  case "|$seen|" in *"|$key|"*)continue;;esac;seen="$seen|$key"
  now="$(date +%s)";due="$(cat "$STATE_DIR/traffic/$key-next" 2>/dev/null)"
  if is_uint "$due" && [ "$due" -gt "$now" ];then traffic_schedule_next "$due";continue;fi
  is_uint "$due" && [ "$((now-due))" -le 180 ] || due="$now"
  candidates="$(traffic_candidates "$user")";attempts=0;success=0;started="$now"
  retry='';message=''
  for uplink in $candidates;do
   attempts=$((attempts+1));[ "$attempts" -le 3 ] || break
   ticket="$("$CODEC_BIN" random16)";case "$ticket" in ''|*[!0-9a-f]*)return 1;;esac;[ "${#ticket}" = 32 ] || return 1
   mkdir "$STATE_DIR/billing/$ticket" || continue
   printf '%s' "$now" >"$STATE_DIR/billing/$ticket/created"
   printf traffic | sha256sum | awk '{print $1}' >"$STATE_DIR/billing/$ticket/owner"
   . "$JSHN_SH";json_init;json_add_string uplink "$uplink";json_add_string account "$section";json_add_string action begin
   json_dump >"$STATE_DIR/billing/$ticket/request.json"
   /bin/sh "${BJUT_BILLING:-/usr/libexec/bjut-billing}" "$ticket" &
   child_register "$!";local billing_pid="$!";wait "$billing_pid";child_forget "$billing_pid"
   result="$STATE_DIR/billing/$ticket/result.json"
   if [ "$(json_file_value "$result" '@.state')" = ready ] && [ -s "$STATE_DIR/billing/$ticket/online.json" ];then
    sampled="$(cat "$STATE_DIR/billing/$ticket/online-at" 2>/dev/null)";is_uint "$sampled" || sampled="$(date +%s)"
    previous="$(cat "$STATE_DIR/traffic/$key-at" 2>/dev/null)"
    cp "$STATE_DIR/billing/$ticket/online.json" "$STATE_DIR/traffic/$key.json.$$" && mv -f "$STATE_DIR/traffic/$key.json.$$" "$STATE_DIR/traffic/$key.json"
    cp "$result" "$STATE_DIR/traffic/$key-meta.json.$$" && mv -f "$STATE_DIR/traffic/$key-meta.json.$$" "$STATE_DIR/traffic/$key-meta.json"
    traffic_rows "$STATE_DIR/traffic/$key.json" >"$STATE_DIR/traffic/$key-devices-$CFG_TRAFFIC_SCOPE.json.$$" && mv -f "$STATE_DIR/traffic/$key-devices-$CFG_TRAFFIC_SCOPE.json.$$" "$STATE_DIR/traffic/$key-devices-$CFG_TRAFFIC_SCOPE.json"
    traffic_history_record "$key" "$STATE_DIR/traffic/$key.json" "$sampled"
    printf '%s' "$sampled" >"$STATE_DIR/traffic/$key-at";rm -f "$STATE_DIR/traffic/$key-error" "$STATE_DIR/traffic/$key.json"
    finished="$(cat "$STATE_DIR/billing/$ticket/online-finished-at" 2>/dev/null)";is_uint "$finished" || finished="$sampled"
    elapsed=$(($(date +%s)-started));log_message info "流量采样：账号 ${user}，上游 ${uplink}，总用时 ${elapsed} 秒，计数请求 $((finished-sampled)) 秒"
    if is_uint "$previous";then elapsed=$((sampled-previous));if [ "$elapsed" -lt 59 ] || [ "$elapsed" -gt 61 ];then log_message notice "流量采样间隔 ${elapsed} 秒：账号 ${user}，已保存真实区间";fi;fi
    success=1;rm -rf "$STATE_DIR/billing/$ticket";break
   fi
   message="$(json_file_value "$result" '@.message')"
   case "$message" in *密码*|*验证码*) retry=$((now+300));;*)retry=$((now+30));;esac
   log_message warning "流量查询失败：账号 ${user}，上游 ${uplink}，${message:-请求未完成}"
   case "$message" in *密码*|*验证码*)rm -rf "$STATE_DIR/billing/$ticket";break;;esac
   rm -rf "$STATE_DIR/billing/$ticket"
  done
  if [ "$success" = 1 ];then
   retry=$((due+60));is_uint "${BJUT_TRAFFIC_ROUND:-}" && retry="$BJUT_TRAFFIC_ROUND";now="$(date +%s)";while [ "$retry" -le "$now" ];do retry=$((retry+60));done
  else
   retry="${retry:-$((now+30))}"
   printf '%s' "${message:-没有可用的查询出口}" >"$STATE_DIR/traffic/$key-error"
  fi
  printf '%s' "$retry" >"$STATE_DIR/traffic/$key-next";traffic_schedule_next "$retry"
 done
}

# Authentication workers notify the sampler without touching other interfaces.
traffic_observe_account() {
 local state="$1" account="$2" old key now file="$STATE_DIR/traffic-account-$UPLINK_ID" monitor reason
 case "$state" in online|authenticated_limited) ;; *)return;;esac
 [ -n "$account" ] || return 0
 old="$(cat "$file" 2>/dev/null)";[ "$old" != "$account" ] || return 0
 printf '%s' "$account" >"$file.$$" && mv -f "$file.$$" "$file"
 now="$(date +%s)";mkdir -p "$STATE_DIR/traffic"
 if [ -n "$old" ];then
  reason="${TRAFFIC_SWITCH_REASON:-检测到上游账号变更}"
  if [ "${FORCE:-0}" = 1 ] && [ "${EVENT:-}" = manual ];then
   case "${MANUAL_ACTION:-}" in switch)reason='手动切换账号';;login|manual)reason='手动登录';;esac
  fi
  reason="$(printf '%s' "$reason" | tr '\011\012\015' '   ')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "interface:$DEVICE" "$DEVICE" "$old" "$account" "$reason" >>"$STATE_DIR/traffic-switches.tsv"

  log_message notice "流量统计检测到换号：${DEVICE}，$old → $account"
 fi
 key="$(printf '%s' "$account" | sha256sum | awk '{print $1}')"
 if [ -z "$old" ] && [ -s "$STATE_DIR/traffic/$key-at" ] && [ ! -s "$STATE_DIR/traffic/$key-error" ];then return 0;fi
 printf '%s' "$now" >"$STATE_DIR/traffic/$key-wake"
 rm -f "$STATE_DIR/traffic/$key-next" "$STATE_DIR/traffic/$key-error"
 monitor="$(cat "$STATE_DIR/traffic-monitor.lock/pid" 2>/dev/null)"
 local stamp="$(cat "$STATE_DIR/traffic-monitor.lock/start" 2>/dev/null)"
 if is_uint "$monitor" && [ -n "$stamp" ] && [ "$stamp" = "$(awk '{print $22}' "/proc/$monitor/stat" 2>/dev/null)" ];then kill -USR1 "$monitor" 2>/dev/null || true;fi
}

traffic_rows() (
 local file="$1" prefix index=0 item key value down mac ip ipv6 identity interface_id interface_name local_device comma=''
 prefix="$(billing_rows_prefix "$file")";printf '['
 while [ "$index" -lt 500 ];do
  item="$prefix[$index]";[ -n "$(json_file_value "$file" "$item.sessionId")" ] || break
  mac="$(billing_mac "$(json_file_value "$file" "$item.mac")")";ip="$(json_file_value "$file" "$item.ip")";ipv6="$(json_file_value "$file" "$item.ipv6")"
  identity="$(traffic_match_identity "$mac" "$ip" "$ipv6")"
  IFS="$(printf '\t')" read -r interface_id interface_name local_device <<END_IDENTITY
$identity
END_IDENTITY
  index=$((index+1))
  [ "${CFG_TRAFFIC_SCOPE:-local}" = all ] || [ "$local_device" = 1 ] || continue
  json_init
  json_add_string interfaceId "$interface_id";json_add_string interfaceName "$interface_name";json_add_boolean local "$local_device"
  for key in loginTime ip ipv6 mac;do
   value="$(json_file_value "$file" "$item.$key")";[ "${#value}" -le 256 ] || value=''
   case "$key" in mac)value="$(billing_format_mac "$value")";;loginTime)key=loginAt;;esac
   json_add_string "$key" "$value"
  done
  down="$(json_file_value "$file" "$item.downFlow")"
  value="$(awk -v d="$down" 'BEGIN{if(d~/^[0-9]+([.][0-9]+)?$/)printf "%.3f",d/1024;else printf "--"}')"
  json_add_string usedFlowMb "$value";printf '%s' "$comma";comma=,;json_dump
 done
 printf ']'
)

traffic_cached() (
 local section user key at flow comma='' seen=''
 if [ "${CFG_TRAFFIC_MONITOR:-0}" != 1 ];then printf '{"enabled":false,"scope":"%s","accounts":[],"history":[],"series":[]}\n' "${CFG_TRAFFIC_SCOPE:-local}";return;fi
 printf '{"enabled":true,"scope":"%s","accounts":[' "${CFG_TRAFFIC_SCOPE:-local}"
 traffic_active_prepare
 for section in $ACCOUNT_SECTIONS;do
  config_get user "$section" username '';[ -n "$user" ] || continue
  traffic_account_selected "$user" || continue
  key="$(printf '%s' "$user" | sha256sum | awk '{print $1}')"
  case "|$seen|" in *"|$key|"*)continue;;esac;seen="$seen|$key"
  at="$(cat "$STATE_DIR/traffic/$key-at" 2>/dev/null)";is_uint "$at" || at=0
  json_init;json_add_string account "$user";json_add_int updatedAt "$at"
  flow="$(json_file_value "$STATE_DIR/traffic/$key-meta.json" '@.remainingFlow')"
  [ "$(json_file_value "$STATE_DIR/traffic/$key-meta.json" '@.remainingFlowUnlimited')" != 1 ] || flow=无限
  json_add_string remainingFlow "$flow"
  json_add_string balance "$(json_file_value "$STATE_DIR/traffic/$key-meta.json" '@.balance')"
  [ ! -s "$STATE_DIR/traffic/$key-error" ] || json_add_string error "$(cat "$STATE_DIR/traffic/$key-error")"
  printf '%s' "$comma";comma=,
  json_dump | sed 's/}[[:space:]]*$/,"devices":/'
  # Normalization belongs to the minute sampler. Frequent UI reads must not
  # start a JSON parser for every field of every device.
  if [ -s "$STATE_DIR/traffic/$key-devices-$CFG_TRAFFIC_SCOPE.json" ];then cat "$STATE_DIR/traffic/$key-devices-$CFG_TRAFFIC_SCOPE.json";else printf '[]';fi
  printf '}'
 done
 printf '],"retention":{"minuteHours":%s,"hourDays":%s,"dayDays":%s,"storageMb":%s},"history":' "${CFG_TRAFFIC_MINUTE_HOURS:-48}" "${CFG_TRAFFIC_HOUR_DAYS:-90}" "${CFG_TRAFFIC_DAY_DAYS:-366}" "${CFG_TRAFFIC_STORAGE_MB:-2}"
 traffic_history_json;printf ',"timeline":';traffic_series_json;printf ',"series":[],"switches":['
 if [ -f "$STATE_DIR/traffic-switches.tsv" ];then
  local change_at change_id change_name change_from change_to change_reason changes_comma=''
  while IFS="$(printf '\t')" read -r change_at change_id change_name change_from change_to change_reason;do
   is_uint "$change_at" || continue
   case "$change_id:$change_name:$change_from:$change_to" in *[!A-Za-z0-9_@:.,-]*)continue;;esac
   json_init;json_add_int at "$change_at";json_add_string interfaceId "$change_id";json_add_string interfaceName "$change_name"
   json_add_string from "$change_from";json_add_string to "$change_to";json_add_string reason "${change_reason:-原因未记录}"
   printf '%s' "$changes_comma";json_dump;changes_comma=,
  done <"$STATE_DIR/traffic-switches.tsv"
 fi
 printf ']}\n'
)

traffic_order_accounts() (
 local section user key value at now index=0 score
 now="$(date +%s)"
 for section in $1;do
  config_get user "$section" username '';key="$(printf '%s' "$user" | sha256sum | awk '{print $1}')"
  at="$(cat "$STATE_DIR/traffic/$key-at" 2>/dev/null)";score=-1
  if is_uint "$at" && [ "$now" -ge "$at" ] && [ "$((now-at))" -le 180 ] && [ ! -s "$STATE_DIR/traffic/$key-error" ];then
   if [ "$(json_file_value "$STATE_DIR/traffic/$key-meta.json" '@.remainingFlowUnlimited')" = 1 ];then
    score=1000000000000000
   else
    value="$(json_file_value "$STATE_DIR/traffic/$key-meta.json" '@.remainingFlow')"
    score="$(awk -v n="$value" 'BEGIN{if(n~/^-?[0-9]+([.][0-9]+)?$/){if(n+0<0)print "1000000000000000";else if(n+0==0)print -2;else print n}else print -1}')"
   fi
  fi
  printf '%s %06d %s\n' "$score" "$index" "$section";index=$((index+1))
 done | sort -k1,1nr -k2,2n | awk '{print $3}'
)
