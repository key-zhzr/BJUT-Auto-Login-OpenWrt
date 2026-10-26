#!/bin/sh
# Billing-only deltas. Fine samples stay in RAM; bounded rollups checkpoint
# every 15 minutes and on a normal stop, rather than writing flash each minute.
traffic_history_prepare() {
 local persisted="${BJUT_TRAFFIC_HISTORY:-/etc/bjut-autologin/usage-samples.tsv}" curves="${BJUT_TRAFFIC_CURVES:-/etc/bjut-autologin/usage-curves.tsv}" size target source
 mkdir -p "$STATE_DIR/traffic-baselines" || return 1
 for target in usage-samples.tsv usage-curves.tsv;do
  [ ! -e "$STATE_DIR/$target" ] || continue
  source="$persisted";[ "$target" != usage-curves.tsv ] || source="$curves"
  if [ -f "$source" ] && [ ! -L "$source" ];then
   size="$(wc -c <"$source" | tr -d ' \011\012\015')"
   is_uint "$size" && [ "$size" -le 2097152 ] && cp "$source" "$STATE_DIR/$target"
  fi
  [ -e "$STATE_DIR/$target" ] || : >"$STATE_DIR/$target"
 done
}

traffic_history_record() (
 local account_key="$1" file="$2" now="$3" prefix index=0 item mac ip ipv6 login down up used device session previous_at previous_used high delta seconds day label identity interface_id interface_name local_device resolution at
 traffic_history_prepare || return 1
 prefix="$(billing_rows_prefix "$file")";day="$(printf '%s' "$now" | "$CODEC_BIN" timestamp-date | cut -c1-10)"
 [ -n "$day" ] || return 1
 while [ "$index" -lt 500 ];do
  item="$prefix[$index]";[ -n "$(json_file_value "$file" "$item.sessionId")" ] || break
  mac="$(billing_mac "$(json_file_value "$file" "$item.mac")")";ip="$(json_file_value "$file" "$item.ip")";ipv6="$(json_file_value "$file" "$item.ipv6")";login="$(json_file_value "$file" "$item.loginTime")"
  down="$(json_file_value "$file" "$item.downFlow")";up="$(json_file_value "$file" "$item.upFlow")"
  used="$(awk -v d="$down" -v u="$up" 'BEGIN{if(d~/^[0-9]+([.][0-9]+)?$/ && u~/^[0-9]+([.][0-9]+)?$/)printf "%.3f",(d+u)/1024}')"
  index=$((index+1));[ -n "$used" ] || continue
  identity="$(traffic_match_identity "$mac" "$ip" "$ipv6")"
  IFS="$(printf '\t')" read -r interface_id interface_name local_device <<END_IDENTITY
$identity
END_IDENTITY
  [ "${CFG_TRAFFIC_SCOPE:-local}" = all ] || [ "$local_device" = 1 ] || continue
  label="$mac";[ -n "$label" ] || label="$ip";case "$label" in ''|*[!a-fA-F0-9:.-]*) label=device;;esac
  identity="$mac";[ -n "$identity" ] || identity="$ip"
  device="$(printf '%s' "$identity" | sha256sum | cut -c1-16)"
  session="$(printf '%s' "$account_key:$device:$ip:$login:$interface_id" | sha256sum | awk '{print $1}')"
  previous_at=0;previous_used="$used"
  [ ! -f "$STATE_DIR/traffic-baselines/$session" ] || read -r previous_at previous_used <"$STATE_DIR/traffic-baselines/$session"
  is_uint "$previous_at" || previous_at=0
  seconds=$((now-previous_at))
  if [ "$seconds" -gt 0 ] && [ "$seconds" -le 180 ];then
   delta="$(awk -v n="$used" -v p="$previous_used" 'BEGIN{if(p~/^[0-9]+([.][0-9]+)?$/ && n>=p)printf "%.3f",n-p}')"
   if [ -n "$delta" ];then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$day" "$account_key" "$device" "$label" "$delta" "$seconds" "$local_device" >>"$STATE_DIR/usage-samples.tsv"
    for resolution in 60 3600 86400;do
     at=$(((now+28800)/resolution*resolution-28800))
     printf '%s\t%s\t%.16s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$resolution" "$at" "$account_key" "$device" "$interface_id" "$interface_name" "$local_device" "$delta" "$seconds" >>"$STATE_DIR/usage-curves.tsv"
    done
   fi
  fi
  high="$(awk -v n="$used" -v p="$previous_used" 'BEGIN{printf "%.3f",(n>p?n:p)}')"
  printf '%s %s\n' "$now" "$high" >"$STATE_DIR/traffic-baselines/$session"
 done
 local oldest="$(printf '%s' "$((now-10368000))" | "$CODEC_BIN" timestamp-date | cut -c1-10)"
 # Old six-column daily rows remain readable for the explicit all-device view.
 awk -F '\t' -v oldest="$oldest" '(NF==6 || NF==7) && $1>=oldest {k=$1 FS $2 FS $3 FS $4 FS ($7==1?1:0);amount[k]+=$5;seconds[k]+=$6} END{for(k in amount){split(k,a,FS);printf "%s\t%s\t%s\t%s\t%.3f\t%.0f\t%s\n",a[1],a[2],a[3],a[4],amount[k],seconds[k],a[5]}}' "$STATE_DIR/usage-samples.tsv" | sort | tail -n 2000 >"$STATE_DIR/usage-samples.tsv.tmp" && mv -f "$STATE_DIR/usage-samples.tsv.tmp" "$STATE_DIR/usage-samples.tsv"
 # 48h minute / 90d hour / 366d day retention, also capped by rows across
 # devices. Tier caps keep the complete checkpoint below ~1.5 MB on a router.
 awk -F '\t' -v now="$now" 'NF==9 && ($1==60 || $1==3600 || $1==86400) && $2<=now && now-$2<=($1==60?172800:($1==3600?7776000:31622400)) {k=$1 FS $2 FS $3 FS $4 FS $5 FS $6 FS $7;amount[k]+=$8;seconds[k]+=$9} END{for(k in amount)printf "%s\t%.3f\t%.0f\n",k,amount[k],seconds[k]}' "$STATE_DIR/usage-curves.tsv" | sort -t "$(printf '\t')" -k2,2nr | awk -F '\t' '++count[$1]<=($1==60?7200:($1==3600?2160:1464))' >"$STATE_DIR/usage-curves.tsv.tmp" && mv -f "$STATE_DIR/usage-curves.tsv.tmp" "$STATE_DIR/usage-curves.tsv"
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
  cp "$STATE_DIR/$target" "$destination.tmp" && chmod 0600 "$destination.tmp" && mv -f "$destination.tmp" "$destination" || return 1
 done
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
 local map section user key prefix source="$STATE_DIR/usage-curves.tsv"
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
 awk -F '\t' -v scope="${CFG_TRAFFIC_SCOPE:-local}" 'BEGIN{n=0;m=0} FILENAME==ARGV[1]{accounts[$1]=$2;next}
 NF==9 && ($1==60 || $1==3600 || $1==86400) && $2~/^[0-9]+$/ && ($3 in accounts) && $4~/^[a-f0-9]+$/ && $5~/^[A-Za-z0-9_:.-]+$/ && $6~/^[A-Za-z0-9_:.-]+$/ && ($7==0 || $7==1) && (scope=="all" || $7==1) && $8~/^[0-9]+([.][0-9]+)?$/ && $9~/^[0-9]+$/ {
  k=$3 FS $4 FS $5 FS $6 FS $7
  if(!(k in channel)){channel[k]=n;channels[n]=accounts[$3] ",\"device\":\"" $4 "\",\"interfaceId\":\"" $5 "\",\"interfaceName\":\"" $6 "\",\"local\":" ($7==1?"true":"false") "}";n++}
  buckets[++m]="[" channel[k] "," $1 "," $2 "," $8 "," $9 "]"
 } END{printf "{\"channels\":[";for(i=0;i<n;i++)printf "%s%s",i?",":"",channels[i];printf "],\"buckets\":[";for(i=1;i<=m;i++)printf "%s%s",(i>1?",":""),buckets[i];printf "]}"}' "$map" "$source"
)
