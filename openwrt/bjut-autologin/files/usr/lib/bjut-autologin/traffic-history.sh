#!/bin/sh
# Bounded sampled history; only continuous deltas, never a NIC counter.
traffic_history_prepare() {
 local persisted="${BJUT_TRAFFIC_HISTORY:-/etc/bjut-autologin/usage-samples.tsv}" size
 mkdir -p "$STATE_DIR/traffic-baselines" || return 1
 [ ! -e "$STATE_DIR/usage-samples.tsv" ] || return 0
 if [ -f "$persisted" ] && [ ! -L "$persisted" ];then
  size="$(wc -c <"$persisted" | tr -d ' \011\012\015')"
  is_uint "$size" && [ "$size" -le 4194304 ] && cp "$persisted" "$STATE_DIR/usage-samples.tsv"
 fi
 [ -e "$STATE_DIR/usage-samples.tsv" ] || : >"$STATE_DIR/usage-samples.tsv"
}

traffic_history_record() (
 local account_key="$1" file="$2" now="$3" prefix index=0 item mac ip login down up used device session previous_at previous_used high delta seconds day label
 traffic_history_prepare || return 1
 prefix="$(billing_rows_prefix "$file")";day="$(printf '%s' "$now" | "$CODEC_BIN" timestamp-date | cut -c1-10)"
 [ -n "$day" ] || day="$(date '+%Y-%m-%d')"
 while [ "$index" -lt 500 ];do
  item="$prefix[$index]";[ -n "$(json_file_value "$file" "$item.sessionId")" ] || break
  mac="$(billing_mac "$(json_file_value "$file" "$item.mac")")";ip="$(json_file_value "$file" "$item.ip")";login="$(json_file_value "$file" "$item.loginTime")"
  down="$(json_file_value "$file" "$item.downFlow")";up="$(json_file_value "$file" "$item.upFlow")"
  used="$(awk -v d="$down" -v u="$up" 'BEGIN{if(d~/^[0-9]+([.][0-9]+)?$/ && u~/^[0-9]+([.][0-9]+)?$/)printf "%.3f",(d+u)/1024}')"
  index=$((index+1));[ -n "$used" ] || continue
  label="$mac";[ -n "$label" ] || label="$ip"
  case "$label" in ''|*[!a-fA-F0-9:.-]*) label=device;;esac
  device="$(printf '%s' "$mac:$ip" | sha256sum | awk '{print $1}')"
  session="$(printf '%s' "$account_key:$device:$login" | sha256sum | awk '{print $1}')"
  previous_at=0;previous_used="$used"
  [ ! -f "$STATE_DIR/traffic-baselines/$session" ] || read -r previous_at previous_used <"$STATE_DIR/traffic-baselines/$session"
  is_uint "$previous_at" || previous_at=0
  seconds=$((now-previous_at))
  if [ "$seconds" -gt 0 ] && [ "$seconds" -le 180 ];then
   delta="$(awk -v n="$used" -v p="$previous_used" 'BEGIN{if(p~/^[0-9]+([.][0-9]+)?$/ && n>=p)printf "%.3f",n-p}')"
   [ -z "$delta" ] || printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$day" "$account_key" "$device" "$label" "$delta" "$seconds" >>"$STATE_DIR/usage-samples.tsv"
  fi
  high="$(awk -v n="$used" -v p="$previous_used" 'BEGIN{printf "%.3f",(n>p?n:p)}')"
  printf '%s %s\n' "$now" "$high" >"$STATE_DIR/traffic-baselines/$session"
 done
 # Persist daily/device totals, not a line per minute. A multi-device home
 # should retain months rather than fill the ledger in a day.
 local oldest="$(printf '%s' "$((now-10368000))" | "$CODEC_BIN" timestamp-date | cut -c1-10)"
 awk -F '\t' -v oldest="$oldest" 'NF==6 && $1>=oldest {k=$1 FS $2 FS $3 FS $4;amount[k]+=$5;seconds[k]+=$6} END{for(k in amount)printf "%s\t%.3f\t%.0f\n",k,amount[k],seconds[k]}' "$STATE_DIR/usage-samples.tsv" | sort | tail -n 10000 >"$STATE_DIR/usage-samples.tsv.tmp" && mv -f "$STATE_DIR/usage-samples.tsv.tmp" "$STATE_DIR/usage-samples.tsv"
 find "$STATE_DIR/traffic-baselines" -type f -mtime +2 -exec rm -f '{}' ';' 2>/dev/null
 traffic_history_checkpoint
)

traffic_history_checkpoint() {
 local now last persisted="${BJUT_TRAFFIC_HISTORY:-/etc/bjut-autologin/usage-samples.tsv}"
 now="$(date +%s)";last="$(cat "$STATE_DIR/traffic-history-saved" 2>/dev/null)"
 [ "${1:-}" = force ] || { is_uint "$last" && [ "$now" -ge "$last" ] && [ "$((now-last))" -lt 900 ] && return 0; }
 [ -f "$STATE_DIR/usage-samples.tsv" ] || return 0
 [ ! -L "$persisted" ] || return 1
 mkdir -p "${persisted%/*}" && chmod 0700 "${persisted%/*}" || return 1
 cp "$STATE_DIR/usage-samples.tsv" "$persisted.tmp" && chmod 0600 "$persisted.tmp" && mv -f "$persisted.tmp" "$persisted" || return 1
 printf '%s' "$now" >"$STATE_DIR/traffic-history-saved"
}

traffic_history_json() (
 local section user key prefix comma='' rowcomma='' seen=''
 traffic_history_prepare || { printf '[]';return; }
 printf '['
 for section in $ACCOUNT_SECTIONS;do
  config_get user "$section" username '';key="$(printf '%s' "$user" | sha256sum | awk '{print $1}')"
  case "|$seen|" in *"|$key|"*)continue;;esac;seen="$seen|$key"
  json_init;json_add_string account "$user";prefix="$(json_dump | sed 's/}[[:space:]]*$//')"
  # All interpolated row fields are numeric or restricted ASCII identifiers.
  rowcomma=''
  awk -F '\t' -v wanted="$key" -v prefix="$prefix" '$2==wanted && NF==6 && $1~/^[0-9-]+$/ && $3~/^[a-f0-9]+$/ && $4~/^[a-fA-F0-9:.-]+$|^device$/ && $5~/^[0-9]+([.][0-9]+)?$/ && $6~/^[0-9]+$/ {k=$1 FS $3 FS $4;amount[k]+=$5;seconds[k]+=$6} END{for(k in amount){split(k,a,FS);printf "%s,\"day\":\"%s\",\"device\":\"%s\",\"label\":\"%s\",\"usedMb\":%.3f,\"sampledSeconds\":%.0f}\n",prefix,a[1],a[2],a[3],amount[k],seconds[k]}}' "$STATE_DIR/usage-samples.tsv" |
  while IFS= read -r row;do printf '%s%s' "$rowcomma" "$row";rowcomma=,;done >"$STATE_DIR/traffic-history-$key.json"
  if [ -s "$STATE_DIR/traffic-history-$key.json" ];then printf '%s' "$comma";cat "$STATE_DIR/traffic-history-$key.json";comma=,;fi
 done
 printf ']'
)
