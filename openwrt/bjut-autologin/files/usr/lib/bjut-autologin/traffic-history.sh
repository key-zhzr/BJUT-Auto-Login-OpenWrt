#!/bin/sh
# Billing-only deltas. Fine samples stay in RAM; bounded rollups checkpoint
# every 15 minutes and on a normal stop, rather than writing flash each minute.
traffic_history_prepare() {
 local persisted="${BJUT_TRAFFIC_HISTORY:-/etc/bjut-autologin/usage-samples.tsv}" curves="${BJUT_TRAFFIC_CURVES:-/etc/bjut-autologin/usage-curves.tsv}" size target source
 mkdir -p "$STATE_DIR/traffic-baselines" || return 1
 if [ ! -f "$STATE_DIR/traffic-switches.tsv" ] && [ -f "${persisted%/*}/usage-switches.tsv" ] && [ ! -L "${persisted%/*}/usage-switches.tsv" ];then tail -n 2000 "${persisted%/*}/usage-switches.tsv" >"$STATE_DIR/traffic-switches.tsv";fi
 for target in usage-samples.tsv usage-curves.tsv;do
  [ ! -e "$STATE_DIR/$target" ] || continue
  source="$persisted";[ "$target" != usage-curves.tsv ] || source="$curves"
  if [ -f "$source" ] && [ ! -L "$source" ];then
   size="$(wc -c <"$source" | tr -d ' \011\012\015')"
   is_uint "$size" && [ "$size" -le "$((${CFG_TRAFFIC_STORAGE_MB:-2}*1048576+4194304))" ] && cp "$source" "$STATE_DIR/$target"
  fi
  [ -e "$STATE_DIR/$target" ] || : >"$STATE_DIR/$target"
 done
}

traffic_history_record() (
 mkdir -p "$STATE_DIR" || return 1
 local history_lock="$STATE_DIR/traffic-history.pid"
 account_lock_acquire "$history_lock" 10 || { log_message warning '流量历史写入等待超时，本次保留采样基线';return 1; }
 trap '[ "$(cat "$history_lock" 2>/dev/null)" != "$$" ] || rm -f "$history_lock"' 0
 traffic_history_record_locked "$@"
)
traffic_history_record_locked() (
 local account_key="$1" file="$2" now="$3" prefix index=0 recorded=0 item mac ip ipv6 login down used device session previous_at previous_used high delta seconds day label identity interface_id interface_name local_device resolution at
 traffic_history_prepare || return 1
 prefix="$(billing_rows_prefix "$file")";day="$(printf '%s' "$now" | "$CODEC_BIN" timestamp-date | cut -c1-10)"
 [ -n "$day" ] || return 1
 while [ "$index" -lt 500 ];do
  item="$prefix[$index]";[ -n "$(json_file_value "$file" "$item.sessionId")" ] || break
  mac="$(billing_mac "$(json_file_value "$file" "$item.mac")")";ip="$(json_file_value "$file" "$item.ip")";ipv6="$(json_file_value "$file" "$item.ipv6")";login="$(json_file_value "$file" "$item.loginTime")"
  down="$(json_file_value "$file" "$item.downFlow")"
  used="$(awk -v d="$down" 'BEGIN{if(d~/^[0-9]+([.][0-9]+)?$/)printf "%.3f",d/1024}')"
  index=$((index+1));[ -n "$used" ] || continue
  identity="$(traffic_match_identity "$mac" "$ip" "$ipv6")"
  IFS="$(printf '\t')" read -r interface_id interface_name local_device <<END_IDENTITY
$identity
END_IDENTITY
  [ "${CFG_TRAFFIC_SCOPE:-local}" = all ] || [ "$local_device" = 1 ] || continue
  recorded=1
  label="$mac";[ -n "$label" ] || label="$ip";case "$label" in ''|*[!a-fA-F0-9:.-]*) label=device;;esac
  identity="$mac";[ -n "$identity" ] || identity="$ip"
  device="$(printf '%s' "$identity" | sha256sum | cut -c1-16)"
  session="$(printf '%s' "$account_key:$device:$ip:$login:$interface_id" | sha256sum | awk '{print $1}')"
  delta='';previous_at=0;previous_used="$used"
  [ ! -f "$STATE_DIR/traffic-baselines/$session" ] || read -r previous_at previous_used <"$STATE_DIR/traffic-baselines/$session"
  is_uint "$previous_at" || previous_at=0
  seconds=$((now-previous_at))
  if [ "$seconds" -gt 0 ] && [ "$seconds" -le 180 ];then
   delta="$(awk -v n="$used" -v p="$previous_used" 'BEGIN{if(p~/^[0-9]+([.][0-9]+)?$/ && n>=p)printf "%.3f",n-p}')"
   if [ -n "$delta" ];then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$day" "$account_key" "$device" "$label" "$delta" "$seconds" "$local_device" >>"$STATE_DIR/usage-samples.tsv"
    for resolution in 60 3600 86400;do
     at=$(((now+28800)/resolution*resolution-28800))
     printf '%s\t%s\t%.16s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$resolution" "$at" "$account_key" "$device" "$interface_id" "$interface_name" "$local_device" "$delta" "$seconds" "$previous_at" "$now" >>"$STATE_DIR/usage-curves.tsv"
    done
   fi
  fi
  if [ "$previous_at" = 0 ];then log_message debug "流量基线建立：$interface_name";
  elif [ "$seconds" -gt 180 ];then log_message notice "流量基线重置：${interface_name}，中断 ${seconds} 秒";
  elif [ -z "${delta:-}" ];then log_message notice "流量计数回退：${interface_name}，保留前次高位";fi
  high="$(awk -v n="$used" -v p="$previous_used" 'BEGIN{printf "%.3f",(n>p?n:p)}')"
  printf '%s %s\n' "$now" "$high" >"$STATE_DIR/traffic-baselines/$session"
 done
 # Empty accounts still publish their actual successful sample timestamp, but
 # have no baseline/history to compact. Do not rewrite all rollups six times.
 [ "$recorded" = 1 ] || return 0
 local oldest="$(printf '%s' "$((now-${CFG_TRAFFIC_DAY_DAYS:-366}*86400))" | "$CODEC_BIN" timestamp-date | cut -c1-10)"
 # Old six-column daily rows remain readable for the explicit all-device view.
 awk -F '\t' -v oldest="$oldest" '(NF==6 || NF==7) && $1>=oldest {k=$1 FS $2 FS $3 FS $4 FS ($7==1?1:0);amount[k]+=$5;seconds[k]+=$6} END{for(k in amount){split(k,a,FS);printf "%s\t%s\t%s\t%s\t%.3f\t%.0f\t%s\n",a[1],a[2],a[3],a[4],amount[k],seconds[k],a[5]}}' "$STATE_DIR/usage-samples.tsv" | sort | tail -n "$((${CFG_TRAFFIC_STORAGE_MB:-2}*1048576/1000))" >"$STATE_DIR/usage-samples.tsv.tmp" && mv -f "$STATE_DIR/usage-samples.tsv.tmp" "$STATE_DIR/usage-samples.tsv"
 # User-defined retention plus a shared row budget across devices.
 # Fine samples have 60%, hours 30%, and days 10% of that budget.
 awk -F '\t' -v now="$now" -v minutes="${CFG_TRAFFIC_MINUTE_HOURS:-48}" -v hours="${CFG_TRAFFIC_HOUR_DAYS:-90}" -v days="${CFG_TRAFFIC_DAY_DAYS:-366}" '(NF==9 || NF==11) && ($1==60 || $1==3600 || $1==86400) && $2<=now && now-$2<=($1==60?minutes*3600:($1==3600?hours*86400:days*86400)) {k=$1 FS $2 FS $3 FS $4 FS $5 FS $6 FS $7;amount[k]+=$8;seconds[k]+=$9;if($10>0 && (!(k in starts) || $10<starts[k]))starts[k]=$10;if($11>ends[k])ends[k]=$11;if(NF==9)legacy[k]=1} END{for(k in amount)printf "%s\t%.3f\t%.0f\t%.0f\t%.0f\n",k,amount[k],seconds[k],legacy[k]?0:starts[k],legacy[k]?0:ends[k]}' "$STATE_DIR/usage-curves.tsv" | sort -t "$(printf '\t')" -k2,2nr | awk -F '\t' -v budget="${CFG_TRAFFIC_STORAGE_MB:-2}" 'BEGIN{capacity=int(budget*1048576/200)} ++count[$1]<=int(capacity*($1==60?.6:($1==3600?.3:.1)))' >"$STATE_DIR/usage-curves.tsv.tmp" && mv -f "$STATE_DIR/usage-curves.tsv.tmp" "$STATE_DIR/usage-curves.tsv"
 find "$STATE_DIR/traffic-baselines" -type f -mtime +2 -exec rm -f '{}' ';' 2>/dev/null
 traffic_history_checkpoint
)

traffic_history_checkpoint() {
 local now last persisted="${BJUT_TRAFFIC_HISTORY:-/etc/bjut-autologin/usage-samples.tsv}" curves="${BJUT_TRAFFIC_CURVES:-/etc/bjut-autologin/usage-curves.tsv}" target destination
 now="$(date +%s)";last="$(cat "$STATE_DIR/traffic-history-saved" 2>/dev/null)"
 [ "${1:-}" = force ] || { is_uint "$last" && [ "$now" -ge "$last" ] && [ "$((now-last))" -lt 900 ] && return 0; }
 for target in usage-samples.tsv usage-curves.tsv;do
  destination="$persisted";[ "$target" != usage-curves.tsv ] || destination="$curves"
  [ -f "$STATE_DIR/$target" ] || continue
  [ ! -L "$destination" ] || return 1
  mkdir -p "${destination%/*}" && chmod 0700 "${destination%/*}" || return 1
  local available required
  available="$(df -Pk "${destination%/*}" 2>/dev/null | awk 'END{print $4}')"
  required="$(wc -c <"$STATE_DIR/$target" | tr -d ' \011\012\015')"
  if is_uint "$available" && is_uint "$required" && [ "$((available*1024))" -lt "$((required+131072))" ];then
   log_message warning '流量历史保存空间不足，保留上次文件，当前采样仍在内存中';return 1
  fi
  cp "$STATE_DIR/$target" "$destination.tmp" && chmod 0600 "$destination.tmp" && mv -f "$destination.tmp" "$destination" || return 1
 done
 if [ -f "$STATE_DIR/traffic-switches.tsv" ];then
  tail -n 2000 "$STATE_DIR/traffic-switches.tsv" >"$STATE_DIR/traffic-switches.tsv.$$" && mv -f "$STATE_DIR/traffic-switches.tsv.$$" "$STATE_DIR/traffic-switches.tsv"
  cp "$STATE_DIR/traffic-switches.tsv" "${persisted%/*}/usage-switches.tsv.tmp" && chmod 0600 "${persisted%/*}/usage-switches.tsv.tmp" && mv -f "${persisted%/*}/usage-switches.tsv.tmp" "${persisted%/*}/usage-switches.tsv"
 fi
 printf '%s' "$now" >"$STATE_DIR/traffic-history-saved"
}

traffic_history_json() (
 local section user key prefix comma='' seen='' rows source="$STATE_DIR/usage-samples.tsv"
 [ -f "$source" ] || source="${BJUT_TRAFFIC_HISTORY:-/etc/bjut-autologin/usage-samples.tsv}"
 [ -f "$source" ] && [ ! -L "$source" ] || { printf '[]';return; }
 printf '['
 for section in $ACCOUNT_SECTIONS;do
  config_get user "$section" username '';key="$(printf '%s' "$user" | sha256sum | awk '{print $1}')"
  case "|$seen|" in *"|$key|"*)continue;;esac;seen="$seen|$key"
  json_init;json_add_string account "$user";prefix="$(json_dump | sed 's/}[[:space:]]*$//')"
  rows="$(awk -F '\t' -v wanted="$key" -v scope="${CFG_TRAFFIC_SCOPE:-local}" -v prefix="$prefix" '$2==wanted && (NF==6 || NF==7) && (scope=="all" || $7==1) && $1~/^[0-9-]+$/ && $3~/^[a-f0-9]+$/ && $4~/^[a-fA-F0-9:.-]+$|^device$/ && $5~/^[0-9]+([.][0-9]+)?$/ && $6~/^[0-9]+$/ {k=$1 FS $3 FS $4 FS ($7==1?1:0);amount[k]+=$5;seconds[k]+=$6} END{comma="";for(k in amount){split(k,a,FS);printf "%s%s,\"day\":\"%s\",\"device\":\"%s\",\"label\":\"%s\",\"local\":%s,\"usedMb\":%.3f,\"sampledSeconds\":%.0f}",comma,prefix,a[1],a[2],a[3],(a[4]==1?"true":"false"),amount[k],seconds[k];comma=","}}' "$source")" || return 1
  if [ -n "$rows" ];then printf '%s%s' "$comma" "$rows";comma=,;fi
 done
 printf ']'
)

traffic_series_json() (
 local map section user key prefix start end resolution monthly source="$STATE_DIR/usage-curves.tsv"
 start="$(request_value start 2>/dev/null)";end="$(request_value end 2>/dev/null)";resolution="$(request_value resolution 2>/dev/null)";monthly="$(request_value monthly 2>/dev/null)"
 is_uint "$start" || start=0;is_uint "$end" || end=41024448000
 case "$resolution" in 60|3600|86400) ;;*)resolution=0;;esac
 case "$monthly" in 1|true)monthly=1;;*)monthly=0;;esac
 [ -f "$source" ] || source="${BJUT_TRAFFIC_CURVES:-/etc/bjut-autologin/usage-curves.tsv}"
 [ -f "$source" ] && [ ! -L "$source" ] || { printf '{"channels":[],"buckets":[]}';return; }
 map="$(mktemp "$STATE_DIR/traffic-map.XXXXXX")" || return 1
 trap 'rm -f "$map"' 0
 for section in $ACCOUNT_SECTIONS;do
  config_get user "$section" username '';key="$(printf '%s' "$user" | sha256sum | cut -c1-16)"
  json_init;json_add_string account "$user";prefix="$(json_dump | tr -d '\n' | sed 's/}[[:space:]]*$//')"
  printf '%s\t%s\n' "$key" "$prefix"
 done >"$map"
 # Dictionary + numeric tuples avoid repeating device/account metadata in
 # thousands of samples and stay below rpcd/App response size limits.
 awk -F '\t' -v scope="${CFG_TRAFFIC_SCOPE:-local}" -v first="$start" -v last="$end" -v resolution="$resolution" -v monthly="$monthly" 'BEGIN{n=0;m=0;day=int((first+28800)/86400)*86400-28800;hour=int((first+28800)/3600)*3600-28800} FILENAME==ARGV[1]{accounts[$1]=$2;next}
 (NF==9 || NF==11) && ($1==60 || $1==3600 || $1==86400) && $2~/^[0-9]+$/ && ($3 in accounts) && $4~/^[a-f0-9]+$/ && $5~/^[A-Za-z0-9_:.-]+$/ && $6~/^[A-Za-z0-9_:.-]+$/ && ($7==0 || $7==1) && (scope=="all" || $7==1) && $8~/^[0-9]+([.][0-9]+)?$/ && $9~/^[0-9]+$/ {
  selected=(resolution==0 || ($1==resolution && $2>=int((first+28800)/resolution)*resolution-28800 && $2<=last))
  prefix=(monthly==1 && $2<first && $2>=first-2764800 && (($1==86400 && $2<day) || ($1==3600 && $2>=day && $2<hour) || ($1==60 && $2>=hour)))
  if(!selected && !prefix)next
  k=$3 FS $4 FS $5 FS $6 FS $7
  if(!(k in channel)){channel[k]=n;channels[n]=accounts[$3] ",\"device\":\"" $4 "\",\"interfaceId\":\"" $5 "\",\"interfaceName\":\"" $6 "\",\"local\":" ($7==1?"true":"false") "}";n++}
  buckets[++m]="[" channel[k] "," $1 "," $2 "," $8 "," $9 (($10>0 && $11>0)?"," $10 "," $11:"") "]"
 } END{printf "{\"channels\":[";for(i=0;i<n;i++)printf "%s%s",i?",":"",channels[i];printf "],\"buckets\":[";for(i=1;i<=m;i++)printf "%s%s",(i>1?",":""),buckets[i];printf "]}"}' "$map" "$source"
)
