#!/bin/sh
# SPDX-License-Identifier: MIT
# Each worker loads one UCI uplink. No shared account, cooldown or response body.

collect_uplink_section() {
	local enabled
	UPLINK_CONFIGURED=1
	config_get_bool enabled "$1" enabled 1
	[ "$enabled" = "1" ] || return 0
	valid_section "$1" || return 1
	UPLINK_SECTIONS="${UPLINK_SECTIONS}${UPLINK_SECTIONS:+ }$1"
}

valid_section() {
	case "$1" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
	[ "${#1}" -le 64 ]
}

select_uplink() {
	local section="$1" option value enabled
	UPLINK_ID="$section"
	[ "$section" != main ] || [ "$UPLINK_CONFIGURED" = 0 ] || return 1
	if [ "$section" != "main" ]; then
		case " $UPLINK_SECTIONS " in *" $section "*) ;; *) return 1 ;; esac
		CFG_DEVICE=""; CFG_DEVICE6=""; CFG_SOURCE4=""; CFG_SOURCE6=""; CFG_NETWORK6=""
		config_get CFG_NETWORK "$section" network ""
		for option in network network6 device device6 source4 source6 transport login_type compatibility expected_ssid expected_bssid; do
			config_get value "$section" "$option" ""
			[ -n "$value" ] || continue
			case "$option" in
				network) CFG_NETWORK="$value" ;; network6) CFG_NETWORK6="$value" ;;
				device) CFG_DEVICE="$value" ;; device6) CFG_DEVICE6="$value" ;;
				source4) CFG_SOURCE4="$value" ;; source6) CFG_SOURCE6="$value" ;;
				transport) CFG_TRANSPORT="$value" ;; login_type) CFG_LOGIN_TYPE="$value" ;;
				compatibility) CFG_COMPATIBILITY="$value" ;;
				expected_ssid) CFG_EXPECTED_SSID="$value" ;; expected_bssid) CFG_EXPECTED_BSSID="$value" ;;
			esac
		done
		config_get CFG_ACCOUNT_ORDER "$section" accounts ""
	fi
	if [ "$UPLINK_CONFIGURED" = "1" ]; then
		STATE_FILE="$STATE_DIR/uplink-$section.json"
		LOCK_DIR="$STATE_DIR/lock-$section"
	fi
	valid_device_name "$CFG_NETWORK" || return 1
	case "$CFG_TRANSPORT" in auto|ethernet|wifi) ;; *) return 1 ;; esac
	CFG_LOGIN_TYPE="$(protocol_internal "$CFG_LOGIN_TYPE")"
	case "$CFG_LOGIN_TYPE" in auto|type1|type2|type3) ;; *) return 1 ;; esac
	case "$CFG_COMPATIBILITY" in secure|legacy_http) ;; *) return 1 ;; esac
	[ -z "$CFG_DEVICE" ] || valid_device_name "$CFG_DEVICE" || return 1
	for value in $CFG_ACCOUNT_ORDER; do
		case " $ACCOUNT_SECTIONS " in *" $value "*) ;; *) return 1 ;; esac
	done
	[ -z "$CFG_NETWORK6" ] || valid_device_name "$CFG_NETWORK6" || return 1
	[ -z "$CFG_DEVICE6" ] || valid_device_name "$CFG_DEVICE6" || return 1
	[ -z "$CFG_SOURCE4" ] || is_campus_ipv4 "$CFG_SOURCE4" || return 1
	[ -z "$CFG_SOURCE6" ] || printf '%s' "$CFG_SOURCE6" | "$CODEC_BIN" validate-ipv6 >/dev/null || return 1
}

read_ipv6_identity() {
	local status detected address
	DEVICE6="$DEVICE"
	NETWORK_JSON6="$NETWORK_JSON4"
	LOCAL_IPV6=""; IPV6_PD=""
	if [ -n "$CFG_NETWORK6" ]; then
		status="$("$UBUS_BIN" -S call "network.interface.$CFG_NETWORK6" status 2>/dev/null)" || return 0
		case "$(network_json_value "$status" '@.up')" in true|1) ;; *) return 0 ;; esac
		NETWORK_JSON6="$status"
		detected="$(network_json_value "$status" '@.l3_device')"
		[ -n "$detected" ] || detected="$(network_json_value "$status" '@.device')"
		DEVICE6="${CFG_DEVICE6:-$detected}"
	else
		DEVICE6="${CFG_DEVICE6:-$DEVICE}"
	fi
	valid_device_name "$DEVICE6" && [ -d "$SYS_NET/$DEVICE6" ] || return 0
	address="$(network_json_value "$NETWORK_JSON6" '@["ipv6-prefix"][0].address')"
	local mask="$(network_json_value "$NETWORK_JSON6" '@["ipv6-prefix"][0].mask')"
	if is_uint "$mask" && [ "$mask" -le 128 ] && printf '%s' "$address" | "$CODEC_BIN" validate-ipv6 >/dev/null 2>&1;then IPV6_PD="$address/$mask";fi
	if command_exists "$IP_BIN"; then
		LOCAL_IPV6="$("$IP_BIN" -6 -o addr show dev "$DEVICE6" scope global 2>/dev/null |
			awk '$0 !~ /tentative|deprecated|dadfailed/ {split($4,a,"/"); if (a[1] ~ /^[23]/) {print a[1]; exit}}')"
	fi
	if [ -n "$CFG_SOURCE6" ]; then
		address="$("$IP_BIN" -6 -o addr show dev "$DEVICE6" scope global 2>/dev/null |
			awk -v wanted="$CFG_SOURCE6" '$0 !~ /tentative|deprecated|dadfailed/ {split($4,a,"/"); if (a[1] == wanted) print a[1]}')"
		LOCAL_IPV6="$address"
	fi
}

curl_supports_ifhost() {
	local version major minor
	[ -n "$CURL_IFHOST" ] && [ "$CURL_IFHOST" = "1" ] && return 0
	[ "$CURL_IFHOST" = "0" ] && return 1
	version="$("$CURL_BIN" --version 2>/dev/null | awk 'NR == 1 {print $2}')"
	major="${version%%.*}"; version="${version#*.}"; minor="${version%%.*}"
	CURL_IFHOST=0
	if is_uint "$major" && is_uint "$minor" && { [ "$major" -gt 8 ] || { [ "$major" -eq 8 ] && [ "$minor" -ge 9 ]; }; }; then
		CURL_IFHOST=1
	fi
	[ "$CURL_IFHOST" = "1" ]
}

mwan_mask() {
	local mask
	mask="$(cat "${BJUT_MWAN_MASK_FILE:-/var/run/mwan3/mmx_mask}" 2>/dev/null)"
	[ -n "$mask" ] || mask="$("$UCI_BIN" -q get mwan3.globals.mmx_mask 2>/dev/null)"
	[ -n "$mask" ] || mask=0x3f00
	case "$mask" in 0x*) case "${mask#0x}" in ''|*[!0-9a-fA-F]*) return 1 ;; esac ;; *) is_uint "$mask" || return 1 ;; esac
	[ "${#mask}" -le 10 ] && [ "$((mask))" -gt 0 ] || return 1
	printf '%s' "$mask"
}

bound_curl() {
	local family="$1" device source mark interface
	shift
	case "$family" in
		ipv6) device="$DEVICE6"; source="$LOCAL_IPV6" ;;
		*) family=ipv4; device="$DEVICE"; source="$LOCAL_IPV4" ;;
	 esac
	[ -n "$source" ] && valid_device_name "$device" || return 99
	if curl_supports_ifhost; then
		interface="ifhost!$device!$source"
	else
		# The mwan3 socket wrapper supplies both bind() and SO_BINDTODEVICE on
		# older curl. Without it, fail rather than silently using another WAN.
		[ "$CFG_MWAN3" = 1 ] && [ -r "$MWAN_WRAPPER" ] || return 98
		interface="if!$device"
	fi
	if [ "$CFG_MWAN3" = "1" ] && [ -r "$MWAN_WRAPPER" ]; then
		mark="$(mwan_mask)" || return 98
		if [ "${BJUT_CURL_EXEC:-0}" = 1 ]; then
			FAMILY="$family" DEVICE="$device" SRCIP="$source" FWMARK="$mark" LD_PRELOAD="$MWAN_WRAPPER"
			export FAMILY DEVICE SRCIP FWMARK LD_PRELOAD
			exec "$CURL_BIN" --interface "$interface" "$@"
		fi
		FAMILY="$family" DEVICE="$device" SRCIP="$source" FWMARK="$mark" \
			LD_PRELOAD="$MWAN_WRAPPER" "$CURL_BIN" --interface "$interface" "$@"
	else
		[ "${BJUT_CURL_EXEC:-0}" != 1 ] || exec "$CURL_BIN" --interface "$interface" "$@"
		"$CURL_BIN" --interface "$interface" "$@"
	fi
}

probe_family() {
	trap - 0
	local family="$1" target directory workers="" pid code all_done success=0
	[ "$family" != "ipv6" ] || [ -n "$LOCAL_IPV6" ] || { printf 'not_configured'; return; }
	for target in configured ustc alidns; do
		directory="$WORK_DIR/$target"; mkdir -p "$directory"
		rm -f "$directory/done" "$directory/ok"
	done
	for target in configured ustc alidns; do
		directory="$WORK_DIR/$target"
		probe_target "$family" "$target" "$directory" & workers="$workers $!"
	done
	while :; do
		all_done=1
		for target in configured ustc alidns; do
			[ -e "$WORK_DIR/$target/done" ] || all_done=0
			[ ! -e "$WORK_DIR/$target/ok" ] || success=1
		done
		[ "$success" = 0 ] && [ "$all_done" = 0 ] || break
		sleep 0.05 2>/dev/null || sleep 1
	done
	for pid in $workers; do kill "$pid" 2>/dev/null || true; done
	for pid in $workers; do wait "$pid" 2>/dev/null || true; done
	if [ "$success" = 1 ]; then printf 'reachable'; else printf 'unreachable'; fi
}

probe_target() {
	trap - 0
	local family="$1" target="$2" directory="$3" url resolve="" code rc curl_pid
	case "$target:$family" in
		configured:*) url="$CFG_ONLINE_URL";;
		ustc:ipv6) url=https://test6.ustc.edu.cn/; resolve='test6.ustc.edu.cn:443:[2001:da8:d800::1043]';;
		ustc:*) url=https://www.baidu.com/robots.txt; resolve='www.baidu.com:443:110.242.69.21';;
		alidns:ipv6) url=https://dns.alidns.com/; resolve='dns.alidns.com:443:[2400:3200::1]';;
		*) url=https://dns.alidns.com/; resolve='dns.alidns.com:443:223.5.5.5';;
	esac
	set -- --silent --show-error --output "$directory/body" --write-out '%{http_code}' --dump-header "$directory/headers" \
		--connect-timeout "$CFG_TIMEOUT" --max-time "$CFG_TIMEOUT" --max-filesize "$MAX_RESPONSE_BYTES" \
		--noproxy '*' --proxy '' --proto '=http,https' --user-agent "BJUT-Auto-Login-OpenWrt/$VERSION"
	if [ "$family" = ipv6 ]; then set -- "$@" --ipv6; else set -- "$@" --ipv4; fi
	[ -z "$resolve" ] || set -- "$@" --resolve "$resolve"
	# exec gives the worker a directly owned curl PID, so early success can
	# cancel the other targets without leaving requests or inherited pipes alive.
	printf 'url = "%s"\n' "$url" | (BJUT_CURL_EXEC=1; bound_curl "$family" "$@" --config -) >"$directory/code" 2>"$directory/error" & curl_pid=$!
	trap 'kill "$curl_pid" 2>/dev/null || true; wait "$curl_pid" 2>/dev/null || true; exit 0' 1 2 15
	wait "$curl_pid"; rc=$?; trap - 1 2 15
	code="$(cat "$directory/code")"
	if [ "$rc" = 0 ]; then
		if [ "$target" = configured ]; then [ "$code" != "$CFG_ONLINE_CODE" ] || : >"$directory/ok"
		else case "$code" in [1-5][0-9][0-9]) : >"$directory/ok";; esac; fi
	fi
	: >"$directory/done"
}

online_check() {
	local pid4 pid6
	# Subshells own their response files; neither family can overwrite the
	# other's result. A blocked IPv4 target cannot hide working IPv6.
	(mkdir -p "$WORK_DIR/p4"; WORK_DIR="$WORK_DIR/p4"; probe_family ipv4) >"$WORK_DIR/probe4" & pid4=$!
	(mkdir -p "$WORK_DIR/p6"; WORK_DIR="$WORK_DIR/p6"; probe_family ipv6) >"$WORK_DIR/probe6" & pid6=$!
	wait "$pid4" 2>/dev/null || true
	wait "$pid6" 2>/dev/null || true
	PROBE4="$(cat "$WORK_DIR/probe4")"; PROBE6="$(cat "$WORK_DIR/probe6")"
	[ "$PROBE4" = reachable ] || [ "$PROBE6" = reachable ]
}

read_portal_session() {
	local protocol="$1" url base resolve profile host total result ips account index row_ip
	SESSION_STATE=unknown
	case "$protocol" in
		type1)
			if [ "$CFG_COMPATIBILITY" = legacy_http ]; then
				base="http://$DORM_GATEWAY:801"; resolve=""; profile=http; host=""
			else
				[ -n "$TYPE1_TLS_HOST" ] || return 0
				base="https://$TYPE1_TLS_HOST:802"; resolve="$TYPE1_TLS_HOST:802:$DORM_GATEWAY"; profile="$TYPE1_TLS_PROFILE"; host="$DORM_GATEWAY:802"
			fi
			url="$base/eportal/portal/online_list?callback=dr1002&user_account=&user_password=&wlan_user_ip=$(urlencode "$LOCAL_IPV4")&jsVersion=4.X&v=$(request_id)&lang=zh"
			http_request "$url" "$base/" "$resolve" "$host" "$profile" || return 0
			load_jsonp || return 0
			result="$(jsonp_value '@.result')"; total="$(jsonp_value '@.total')"
			ips="$(printf '%s' "$JSONP_PAYLOAD" | "$JSONFILTER_BIN" -e '@.list[*].online_ip' 2>/dev/null)"
			if [ "$result" = 1 ] && printf '%s\n' "$ips" | grep -Fxq "$LOCAL_IPV4"; then
				SESSION_STATE=online
				# External scripts may have switched this port's account. Report
				# only the server-confirmed row for this exact physical source.
				index=0
				while [ "$index" -lt 64 ]; do
					row_ip="$(jsonp_value "@.list[$index].online_ip")"
					[ -n "$row_ip" ] || break
					if [ "$row_ip" = "$LOCAL_IPV4" ]; then
						account="$(jsonp_value "@.list[$index].user_account")"
						case "$account" in ''|*[!A-Za-z0-9_@.,-]*) ;; *)
							OBSERVED_ACCOUNT="$(mask_username "$account")"; RUNTIME_ACCOUNT="$OBSERVED_ACCOUNT" ;;
						esac
						break
					fi
					index=$((index + 1))
				done
			elif [ "$result" = 1 ] && [ "$total" = 0 ] && [ "$(jsonp_value '@.list' | tr -d ' \011\012\015')" = '[]' ]; then
				SESSION_STATE=offline
			elif [ "$result" = 0 ]; then
				case "$(jsonp_value '@.msg')" in *未认证*|*未登录*|*未在线*|*不在线*|*not\ online*|*not\ authenticated*|*获取用户在线信息数据为空*) SESSION_STATE=offline ;; esac
			fi
			;;
		type2)
			probe_type2 || return 0
			result="$(jsonp_value '@.result')"
			case "$result" in 1) SESSION_STATE=online ;; 0) SESSION_STATE=offline ;; esac
			;;
		type3)
			lgn_user_info_probe || return 0
			result="$(jsonp_value '@.code')"
			if [ "$result" = 1 ]; then
				account="$(jsonp_value '@.user_info.account')"
				if [ -z "$account" ]; then SESSION_STATE=offline; else
					case "$account" in *[!A-Za-z0-9_@.,-]*) ;; *)
						SESSION_STATE=online; OBSERVED_ACCOUNT="$(mask_username "$account")"; RUNTIME_ACCOUNT="$OBSERVED_ACCOUNT" ;;
					esac
				fi
			fi
			;;
		esac
}

print_all_status() {
	local section comma="" item
	printf '{"generated_at":%s,"apiVersion":1,"version":"%s","capabilities":["dashboard","ports","billing","logs","settings","account_set","account_manage","uplink_manage","billing_records","log_settings","pushplus","pushplus_status","uplink_actions","billing_actions","operations","account_limits","billing_background","device_usage","traffic_charts","traffic_compression","billing_center","maintenance"],"uplinks":[' "$(date +%s)" "$VERSION"
	for section in $UPLINK_SECTIONS; do
		item="$STATE_DIR/uplink-$section.json"
		[ "$section" != main ] || [ "$UPLINK_CONFIGURED" = 1 ] || item="$STATE_DIR/status.json"
		printf '%s' "$comma"; comma=,
		print_status_file "$item" "$section"
	done
	printf ']}\n'
}

run_all_uplinks() {
	local section batch=0 pids="" pid rc=0 result
	mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR" || return 1
	prune_uplink_routes
	prune_mwan_rules || log_message error "出口规则暂未更新，请先应用 mwan3 中的待保存修改"
	if [ "$UPLINK_CONFIGURED" = 0 ]; then
		UPLINK_ID=main; run_once_locked; return $?
	fi
	for section in $UPLINK_SECTIONS; do
		(BJUT_EVENT="$EVENT" /bin/sh "$SELF_BIN" "${FORCE_COMMAND:-once}" "$section") & pids="$pids $!"
		CHILD_PIDS="$pids"
		batch=$((batch + 1))
		if [ "$batch" -ge 4 ]; then
			for pid in $pids; do wait "$pid" || rc=1; CHILD_PIDS="${CHILD_PIDS# $pid}"; done
			batch=0; pids=""; CHILD_PIDS=""
		fi
	done
	for pid in $pids; do wait "$pid" || rc=1; CHILD_PIDS="${CHILD_PIDS# $pid}"; done
	print_all_status >"$STATE_DIR/status.json.$$" && mv -f "$STATE_DIR/status.json.$$" "$STATE_DIR/status.json"
	return "$rc"
}

acquire_source_lock() {
 local key owner
 # Validated identity is unique without an optional BusyBox applet or hash.
 valid_device_name "$DEVICE" || return 1
 if is_campus_ipv4 "$LOCAL_IPV4";then key="$DEVICE-$LOCAL_IPV4"
 else
  case "$LOCAL_IPV6" in 2001:da8:216:*) ;; *) return 1;;esac
  printf '%s' "$LOCAL_IPV6" | "$CODEC_BIN" validate-ipv6 >/dev/null || return 1
  key="$DEVICE6-$(printf '%s' "$LOCAL_IPV6" | tr ':' '_')"
 fi
 SOURCE_LOCK="$STATE_DIR/source-$key.lock"
 SOURCE_STATE="$STATE_DIR/source-$key.json"
 if ! mkdir "$SOURCE_LOCK" 2>/dev/null; then
  owner="$(cat "$SOURCE_LOCK/pid" 2>/dev/null)"
  is_uint "$owner" && kill -0 "$owner" 2>/dev/null && return 1
  rm -rf -- "$SOURCE_LOCK"
  mkdir "$SOURCE_LOCK" 2>/dev/null || return 1
 fi
 printf '%s' "$$" >"$SOURCE_LOCK/pid"
 SOURCE_LOCK_HELD=1
}
