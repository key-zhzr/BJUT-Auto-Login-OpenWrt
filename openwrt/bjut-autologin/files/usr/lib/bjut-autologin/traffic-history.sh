#!/bin/sh
# Billing-only deltas. Fine samples stay in RAM; bounded rollups checkpoint
# every 15 minutes and on a normal stop, rather than writing flash each minute.
traffic_history_prepare() {
 local persisted="${BJUT_TRAFFIC_HISTORY:-/etc/bjut-autologin/usage-samples.tsv}" curves="${BJUT_TRAFFIC_CURVES:-/etc/bjut-autologin/usage-curves.tsv}"
 mkdir -p "$STATE_DIR/traffic-baselines" || return 1
 if [ ! -f "$STATE_DIR/traffic-switches.tsv" ] && [ -f "${persisted%/*}/usage-switches.tsv" ] && [ ! -L "${persisted%/*}/usage-switches.tsv" ];then
  cp "${persisted%/*}/usage-switches.tsv" "$STATE_DIR/traffic-switches.tsv" || return 1
 fi
 [ -f "$STATE_DIR/traffic-store-current" ] ||
  "${BJUT_TRAFFIC_STORE:-/usr/libexec/bjut-traffic-store}" init "$STATE_DIR" "$persisted" "$curves" || {
   log_message error '流量历史读取失败，已保留原文件';return 1;
  }
}
traffic_history_directory() {
 "${BJUT_TRAFFIC_STORE:-/usr/libexec/bjut-traffic-store}" path "$STATE_DIR"
}
traffic_history_stream() {
 "${BJUT_TRAFFIC_STORE:-/usr/libexec/bjut-traffic-store}" stream "$1" "$STATE_DIR" ${2:+"$2"} ${3:+"$3"}
}

traffic_history_record() (
 mkdir -p "$STATE_DIR" || return 1
 local history_lock="$STATE_DIR/traffic-history.pid"
 account_lock_acquire "$history_lock" 60 || { log_message warning '流量历史写入等待超时，本次保留采样基线';return 1; }
 trap '[ "$(cat "$history_lock" 2>/dev/null)" != "$$" ] || rm -f "$history_lock"' 0
 BJUT_HISTORY_HELD=1 traffic_history_record_locked "$@"
)
traffic_history_record_locked() (
 local account_key="$1" file="$2" now="$3" prefix index=0 recorded=0 item mac ip ipv6 login down used device session previous_at previous_used high delta seconds day label identity interface_id interface_name local_device resolution at
 traffic_history_prepare || return 1
 local history_directory="$(traffic_history_directory)"
 [ -n "$history_directory" ] || return 1
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
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$day" "$account_key" "$device" "$label" "$delta" "$seconds" "$local_device" >>"$history_directory/usage-samples.tsv" || return 1
    for resolution in 60 3600 86400;do
     at=$(((now+28800)/resolution*resolution-28800))
     printf '%s\t%s\t%.16s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$resolution" "$at" "$account_key" "$device" "$interface_id" "$interface_name" "$local_device" "$delta" "$seconds" "$previous_at" "$now" >>"$history_directory/usage-curves.tsv" || return 1
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
 find "$STATE_DIR/traffic-baselines" -type f -mtime +2 -exec rm -f '{}' ';' 2>/dev/null
 # Append-only between checkpoints. RAM expansion and staging are not charged
 # to the Flash quota, and are never restored as a months-long plain TSV.
 traffic_history_checkpoint periodic "$now" || true
)

traffic_history_checkpoint() (
 local now="${2:-$(date +%s)}" last attempted persisted="${BJUT_TRAFFIC_HISTORY:-/etc/bjut-autologin/usage-samples.tsv}" curves="${BJUT_TRAFFIC_CURVES:-/etc/bjut-autologin/usage-curves.tsv}" work target destination available required total=0 trimmed
 local history_lock="$STATE_DIR/traffic-history.pid" store="${BJUT_TRAFFIC_STORE:-/usr/libexec/bjut-traffic-store}"
 last="$(cat "$STATE_DIR/traffic-history-saved" 2>/dev/null)"
 [ "${1:-}" = force ] || { is_uint "$last" && [ "$now" -ge "$last" ] && [ "$((now-last))" -lt 900 ] && return 0; }
 attempted="$(cat "$STATE_DIR/traffic-history-attempt" 2>/dev/null)"
 [ "${1:-}" = force ] || { is_uint "$attempted" && [ "$now" -ge "$attempted" ] && [ "$((now-attempted))" -lt 900 ] && return 0; }
 if [ "${BJUT_HISTORY_HELD:-0}" != 1 ];then
  account_lock_acquire "$history_lock" 60 || return 1
  trap '[ "$(cat "$history_lock" 2>/dev/null)" != "$$" ] || rm -f "$history_lock"' 0
 fi
 traffic_history_prepare || return 1
 printf '%s' "$now" >"$STATE_DIR/traffic-history-attempt"
 work="$(mktemp -d "$STATE_DIR/traffic-checkpoint.XXXXXX")" || return 1
 if ! "$store" compact "$STATE_DIR" "$work" "$now" "${CFG_TRAFFIC_MINUTE_HOURS:-48}" "${CFG_TRAFFIC_HOUR_DAYS:-90}" "${CFG_TRAFFIC_DAY_DAYS:-366}" "$((${CFG_TRAFFIC_STORAGE_MB:-2}*1048576))" 0 >"$work/storage.json";then
  rm -rf "$work";log_message error '流量历史整理失败，当前采样与上次文件均已保留';return 1
 fi
 # Stage and validate in RAM first; require room for the atomic Flash copies.
 # The shared Flash quota includes both gzip files, their seek index, and switches.
 for target in usage-samples.tsv.dict.gz usage-curves.tsv.dict.gz usage-switches.tsv usage-curves.tsv.index;do
  required="$(wc -c <"$work/$target" | tr -d ' \011\012\015')";total=$((total+required))
 done
 for destination in "${persisted%/*}" "${curves%/*}";do
  mkdir -p "$destination" && chmod 0700 "$destination" || { rm -rf "$work";return 1; }
  available="$(df -Pk "$destination" 2>/dev/null | awk 'END{print $4}')"
  if is_uint "$available" && [ "$((available*1024))" -lt "$((total+131072))" ];then
   rm -rf "$work";log_message warning 'Flash 可用空间不足，当前采样仍保留在内存中';return 1
  fi
 done
 for target in usage-samples.tsv.dict.gz usage-curves.tsv.dict.gz usage-switches.tsv usage-curves.tsv.index;do
  case "$target" in usage-samples*)destination="$persisted.dict.gz";;usage-curves.tsv.index)destination="$curves.index";;usage-curves*)destination="$curves.dict.gz";;*)destination="${persisted%/*}/usage-switches.tsv";;esac
  if [ -L "$destination" ] || [ -e "$destination.tmp.$$" ] || [ -L "$destination.tmp.$$" ] ||
     ! cp "$work/$target" "$destination.tmp.$$" || ! chmod 0600 "$destination.tmp.$$";then
   rm -f "$persisted.dict.gz.tmp.$$" "$curves.dict.gz.tmp.$$" "$curves.index.tmp.$$" "${persisted%/*}/usage-switches.tsv.tmp.$$"
   rm -rf "$work";return 1
  fi
 done
 for destination in "$persisted.dict.gz" "$curves.dict.gz" "$curves.index" "${persisted%/*}/usage-switches.tsv";do
  mv -f "$destination.tmp.$$" "$destination" || { rm -rf "$work";return 1; }
 done
 if ! "$store" commit "$STATE_DIR" "$work";then
  rm -rf "$work";log_message error '流量历史切换失败，已保留当前采样以便重试';return 1
 fi
 rm -f "$persisted" "$curves" "$STATE_DIR/usage-samples.tsv" "$STATE_DIR/usage-curves.tsv"
 cp "$work/storage.json" "$STATE_DIR/traffic-storage.json.$$" && mv -f "$STATE_DIR/traffic-storage.json.$$" "$STATE_DIR/traffic-storage.json"
 trimmed="$(json_file_value "$work/storage.json" '@.trimmedRows')"
 [ "${trimmed:-0}" = 0 ] || log_message notice "流量历史已达到 Flash 容量上限，清理最早的 ${trimmed} 条记录"
 rm -rf "$work"
 printf '%s' "$now" >"$STATE_DIR/traffic-history-saved"
)

traffic_history_json() (
 local section user key prefix comma='' seen='' rows
 traffic_history_prepare || { printf '[]';return; }
 printf '['
 for section in $ACCOUNT_SECTIONS;do
  config_get user "$section" username '';key="$(printf '%s' "$user" | sha256sum | awk '{print $1}')"
  case "|$seen|" in *"|$key|"*)continue;;esac;seen="$seen|$key"
  json_init;json_add_string account "$user";prefix="$(json_dump | sed 's/}[[:space:]]*$//')"
  rows="$(traffic_history_stream samples | awk -F '\t' -v wanted="$key" -v scope="${CFG_TRAFFIC_SCOPE:-local}" -v prefix="$prefix" '$2==wanted && (NF==6 || NF==7) && (scope=="all" || $7==1) && $1~/^[0-9-]+$/ && $3~/^[a-f0-9]+$/ && $4~/^[a-fA-F0-9:.-]+$|^device$/ && $5~/^[0-9]+([.][0-9]+)?$/ && $6~/^[0-9]+$/ {k=$1 FS $3 FS $4 FS ($7==1?1:0);amount[k]+=$5;seconds[k]+=$6} END{comma="";for(k in amount){split(k,a,FS);printf "%s%s,\"day\":\"%s\",\"device\":\"%s\",\"label\":\"%s\",\"local\":%s,\"usedMb\":%.3f,\"sampledSeconds\":%.0f}",comma,prefix,a[1],a[2],a[3],(a[4]==1?"true":"false"),amount[k],seconds[k];comma=","}}')" || return 1
  if [ -n "$rows" ];then printf '%s%s' "$comma" "$rows";comma=,;fi
 done
 printf ']'
)

traffic_series_json() (
 local map section user key prefix start end resolution monthly
 traffic_history_prepare || { printf '{"channels":[],"buckets":[]}';return; }
 start="$(request_value start 2>/dev/null)";end="$(request_value end 2>/dev/null)";resolution="$(request_value resolution 2>/dev/null)";monthly="$(request_value monthly 2>/dev/null)"
 is_uint "$start" || start=0;is_uint "$end" || end=41024448000
 case "$resolution" in 60|3600|86400) ;;*)resolution=0;;esac
 case "$monthly" in 1|true)monthly=1;;*)monthly=0;;esac
 map="$(mktemp "$STATE_DIR/traffic-map.XXXXXX")" || return 1
 trap 'rm -f "$map"' 0
 for section in $ACCOUNT_SECTIONS;do
  config_get user "$section" username '';key="$(printf '%s' "$user" | sha256sum | cut -c1-16)"
  json_init;json_add_string account "$user";prefix="$(json_dump | tr -d '\n' | sed 's/}[[:space:]]*$//')"
  printf '%s\t%s\n' "$key" "$prefix"
 done >"$map"
 # Dictionary + numeric tuples avoid repeating device/account metadata in
 # thousands of samples and stay below rpcd/App response size limits.
 local seek_start="$start"
 if [ "$monthly" = 1 ] && [ "$start" -gt 2764800 ];then seek_start=$((start-2764800));elif [ "$resolution" -gt 0 ];then seek_start=$(((start+28800)/resolution*resolution-28800));[ "$seek_start" -ge 0 ] || seek_start=0;fi
 traffic_history_stream curves "$seek_start" "$end" | awk -F '\t' -v scope="${CFG_TRAFFIC_SCOPE:-local}" -v first="$start" -v last="$end" -v resolution="$resolution" -v monthly="$monthly" 'BEGIN{n=0;m=0;day=int((first+28800)/86400)*86400-28800;hour=int((first+28800)/3600)*3600-28800} FILENAME==ARGV[1]{accounts[$1]=$2;next}
 (NF==9 || NF==11) && ($1==60 || $1==3600 || $1==86400) && $2~/^[0-9]+$/ && ($3 in accounts) && $4~/^[a-f0-9]+$/ && $5~/^[A-Za-z0-9_:.-]+$/ && $6~/^[A-Za-z0-9_:.-]+$/ && ($7==0 || $7==1) && (scope=="all" || $7==1) && $8~/^[0-9]+([.][0-9]+)?$/ && $9~/^[0-9]+$/ {
  selected=(resolution==0 || ($1==resolution && $2>=int((first+28800)/resolution)*resolution-28800 && $2<=last))
  prefix=(monthly==1 && $2<first && $2>=first-2764800 && (($1==86400 && $2<day) || ($1==3600 && $2>=day && $2<hour) || ($1==60 && $2>=hour)))
  if(!selected && !prefix)next
  k=$3 FS $4 FS $5 FS $6 FS $7
  if(!(k in channel)){channel[k]=n;channels[n]=accounts[$3] ",\"device\":\"" $4 "\",\"interfaceId\":\"" $5 "\",\"interfaceName\":\"" $6 "\",\"local\":" ($7==1?"true":"false") "}";n++}
  buckets[++m]="[" channel[k] "," $1 "," $2 "," $8 "," $9 (($10>0 && $11>0)?"," $10 "," $11:"") "]"
 } END{printf "{\"channels\":[";for(i=0;i<n;i++)printf "%s%s",i?",":"",channels[i];printf "],\"buckets\":[";for(i=1;i<=m;i++)printf "%s%s",(i>1?",":""),buckets[i];printf "]}"}' "$map" -
)
