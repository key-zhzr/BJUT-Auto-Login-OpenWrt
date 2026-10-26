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
 done | sort -u >"$STATE_DIR/traffic-identities.tsv.tmp"
 mv -f "$STATE_DIR/traffic-identities.tsv.tmp" "$STATE_DIR/traffic-identities.tsv"
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

traffic_collect() {
 local section user password key uplink candidate assigned ticket now result retry seen=''
 [ "${CFG_TRAFFIC_MONITOR:-0}" = 1 ] || return 0
 TRAFFIC_NEXT_AT="$(($(date +%s)+60))"
 traffic_identity_prepare
 mkdir -p "$STATE_DIR/traffic" "$STATE_DIR/billing" || return 1
 for section in $ACCOUNT_SECTIONS; do
  config_get user "$section" username '';config_get password "$section" password ''
  [ -n "$user" ] && [ -n "$password" ] || continue
  key="$(printf '%s' "$user" | sha256sum | awk '{print $1}')"
  case "|$seen|" in *"|$key|"*) continue;;esac;seen="$seen|$key"
  now="$(date +%s)";retry="$(cat "$STATE_DIR/traffic/$key-next" 2>/dev/null)"
  if is_uint "$retry" && [ "$retry" -gt "$now" ];then
   traffic_schedule_next "$retry"
   continue
  fi
  uplink=''
  for candidate in $UPLINK_SECTIONS;do
   assigned="$(json_file_value "$STATE_DIR/uplink-$candidate.json" '@.account')"
   if [ "$assigned" = "$user" ];then uplink="$candidate";break;fi
  done
  if [ -z "$uplink" ];then
   for candidate in $UPLINK_SECTIONS;do
    config_get assigned "$candidate" accounts ''
    case " $assigned " in *" $section "*|'  ') uplink="$candidate";break;;esac
   done
  fi
  [ -n "$uplink" ] || continue
  ticket="$("$CODEC_BIN" random16)";case "$ticket" in ''|*[!0-9a-f]*)return 1;;esac;[ "${#ticket}" = 32 ] || return 1
  mkdir "$STATE_DIR/billing/$ticket" || continue
  printf '%s' "$now" >"$STATE_DIR/billing/$ticket/created"
  printf traffic | sha256sum | awk '{print $1}' >"$STATE_DIR/billing/$ticket/owner"
  # Use the same verified dashboard parsing as the interactive overview.
  # Embedded leftFlow may be zero while the rendered available-flow metric
  # includes the account's current plan allowance.
  . "$JSHN_SH";json_init;json_add_string uplink "$uplink";json_add_string account "$section";json_add_string action begin
  json_dump >"$STATE_DIR/billing/$ticket/request.json"
  /bin/sh "${BJUT_BILLING:-/usr/libexec/bjut-billing}" "$ticket"
  result="$STATE_DIR/billing/$ticket/result.json"
  if [ "$(json_file_value "$result" '@.state')" = ready ] && [ -s "$STATE_DIR/billing/$ticket/online.json" ];then
   cp "$STATE_DIR/billing/$ticket/online.json" "$STATE_DIR/traffic/$key.json.$$" && mv -f "$STATE_DIR/traffic/$key.json.$$" "$STATE_DIR/traffic/$key.json"
   cp "$result" "$STATE_DIR/traffic/$key-meta.json.$$" && mv -f "$STATE_DIR/traffic/$key-meta.json.$$" "$STATE_DIR/traffic/$key-meta.json"
   traffic_rows "$STATE_DIR/traffic/$key.json" >"$STATE_DIR/traffic/$key-devices-$CFG_TRAFFIC_SCOPE.json.$$" && mv -f "$STATE_DIR/traffic/$key-devices-$CFG_TRAFFIC_SCOPE.json.$$" "$STATE_DIR/traffic/$key-devices-$CFG_TRAFFIC_SCOPE.json"
   date +%s >"$STATE_DIR/traffic/$key-at";rm -f "$STATE_DIR/traffic/$key-error"
   traffic_history_record "$key" "$STATE_DIR/traffic/$key.json" "$(date +%s)"
   rm -f "$STATE_DIR/traffic/$key.json"
   retry=$((now+60))
  else
   printf '%s' '查询暂未完成，请在计费中心核对账号或验证码' >"$STATE_DIR/traffic/$key-error"
   retry=$((now+300))
  fi
  printf '%s' "$retry" >"$STATE_DIR/traffic/$key-next"
  traffic_schedule_next "$retry"
  rm -rf "$STATE_DIR/billing/$ticket"
 done
}

traffic_rows() (
 local file="$1" prefix index=0 item key value down up mac ip ipv6 identity interface_id interface_name local_device comma=''
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
  down="$(json_file_value "$file" "$item.downFlow")";up="$(json_file_value "$file" "$item.upFlow")"
  value="$(awk -v d="$down" -v u="$up" 'BEGIN{if(d~/^[0-9]+([.][0-9]+)?$/ && u~/^[0-9]+([.][0-9]+)?$/)printf "%.3f",(d+u)/1024;else printf "--"}')"
  json_add_string usedFlowMb "$value";printf '%s' "$comma";comma=,;json_dump
 done
 printf ']'
)

traffic_cached() (
 local section user key at flow comma='' seen=''
 if [ "${CFG_TRAFFIC_MONITOR:-0}" != 1 ];then printf '{"enabled":false,"scope":"%s","accounts":[],"history":[],"series":[]}\n' "${CFG_TRAFFIC_SCOPE:-local}";return;fi
 printf '{"enabled":true,"scope":"%s","accounts":[' "${CFG_TRAFFIC_SCOPE:-local}"
 for section in $ACCOUNT_SECTIONS;do
  config_get user "$section" username '';[ -n "$user" ] || continue
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
 printf '],"history":';traffic_history_json;printf ',"timeline":';traffic_series_json;printf ',"series":[]}\n'
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
