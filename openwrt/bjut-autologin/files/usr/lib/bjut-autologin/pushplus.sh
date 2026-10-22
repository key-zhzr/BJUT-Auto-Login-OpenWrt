#!/bin/sh
# SPDX-License-Identifier: MIT
# Only state changes enqueue messages. Sending is detached from the uplink's
# locks and uses the system route, so another WAN can report a failed uplink.

valid_pushplus_token() {
	case "$1" in *[!A-Za-z0-9_-]*) return 1;; esac
	[ "${#1}" -le 256 ]
}

valid_pushplus_topic() {
	case "$1" in *[!A-Za-z0-9_-]*) return 1;; esac
	[ "${#1}" -le 64 ]
}

pushplus_ready() {
	[ "${CFG_PUSHPLUS_ENABLED:-0}" = 1 ] && [ -n "$CFG_PUSHPLUS_TOKEN" ] &&
		valid_pushplus_token "$CFG_PUSHPLUS_TOKEN" && valid_pushplus_topic "$CFG_PUSHPLUS_TOPIC" &&
		valid_range "$CFG_PUSHPLUS_DELAY" 10 3600 && valid_range "$CFG_PUSHPLUS_INTERVAL" 60 86400
}

pushplus_start_sender() {
	local directory="$1" now="$2" started attempt_sequence attempted sequence
	[ -s "$directory/pending.json" ] || return 0
	sequence="$(json_file_value "$directory/pending.json" '@.sequence')"
	[ ! -r "$directory/attempt" ] || read -r attempt_sequence attempted <"$directory/attempt"
	# A failed request is retried at most once a minute. A new event (especially
	# recovery) can be sent immediately, replacing an obsolete queued warning.
	if [ "$sequence" = "$attempt_sequence" ] && is_uint "$attempted" &&
		[ "$now" -ge "$attempted" ] && [ "$((now - attempted))" -lt 60 ]; then return 0; fi
	if ! mkdir "$directory/sending" 2>/dev/null; then
		started="$(cat "$directory/sending/started" 2>/dev/null)"
		is_uint "$started" && [ "$now" -ge "$started" ] && [ "$((now - started))" -lt 60 ] && return 0
		rm -rf -- "$directory/sending"
		mkdir "$directory/sending" 2>/dev/null || return 0
	fi
	printf '%s\n' "$now" >"$directory/sending/started"
	(
		trap - 0 1 2 15
		trap 'rm -rf -- "$directory/sending"' 0
		pushplus_send "$directory" "$now"
	) </dev/null >/dev/null 2>&1 &
}

pushplus_send() {
	local directory="$1" now="$2" job="$1/sending/message.json" sequence title content http code
	mv "$directory/pending.json" "$job" || return 1
	sequence="$(json_file_value "$job" '@.sequence')"
	title="$(json_file_value "$job" '@.title')"
	content="$("$JSONFILTER_BIN" -i "$job" -e '@.content' 2>/dev/null)"
	printf '%s %s\n' "$sequence" "$now" >"$directory/attempt"
	. "$JSHN_SH"
	json_init
	json_add_string token "$CFG_PUSHPLUS_TOKEN"
	json_add_string title "$title"
	json_add_string content "$content"
	json_add_string template txt
	json_add_string channel wechat
	[ -z "$CFG_PUSHPLUS_TOPIC" ] || json_add_string topic "$CFG_PUSHPLUS_TOPIC"
	# The token travels in stdin, never curl arguments or a URL. Do not follow
	# redirects, expose response bodies in logs, or reuse portal TLS exceptions.
	http="$(json_dump | "$CURL_BIN" --disable --silent --show-error --noproxy '*' \
		--proto '=https' --connect-timeout 3 --max-time 8 --max-filesize 16384 \
		--request POST --header 'Content-Type: application/json' --data-binary @- \
		--output "$directory/sending/response.json" --write-out '%{http_code}' \
		--url 'https://www.pushplus.plus/send' 2>/dev/null)" || http=000
	code="$(json_file_value "$directory/sending/response.json" '@.code')"
	if [ "$http" = 200 ] && [ "$code" = 200 ]; then
		# PushPlus is asynchronous: code=200 only acknowledges receipt.
		log_message info 'PushPlus 已受理消息'
	else
		log_message warning 'PushPlus 请求未成功，将稍后重试'
		# Never restore an old failure after a newer event or manual logout.
		if [ "$(json_file_value "$directory/state.json" '@.sequence')" = "$sequence" ]; then
			ln "$job" "$directory/pending.json" 2>/dev/null || true
		fi
		return 1
	fi
}

pushplus_observe() (
	# Isolate jshn variables and traps from the authentication state machine.
	trap - 0 1 2 15
	pushplus_ready || return 0
	valid_section "$UPLINK_ID" || return 0
	local state="$1" message="$2" protocol="$3" account="$4" now="$5"
	local directory="$STATE_DIR/pushplus/$UPLINK_ID" group='' old_account='' since=0 login=0 alerted=0
	local last_event='' last_time=0 sequence=0 event='' title='' immediate=0 temporary
	mkdir -p "$directory" || return 0
	. "$JSHN_SH"
	if [ -s "$directory/state.json" ] && json_load "$(cat "$directory/state.json")"; then
		json_get_var group group; json_get_var old_account account; json_get_var since since
		json_get_var login login; json_get_var alerted alerted
		json_get_var last_event last_event; json_get_var last_time last_time; json_get_var sequence sequence
	fi
	is_uint "$since" || since=0; is_uint "$last_time" || last_time=0; is_uint "$sequence" || sequence=0
	case "$state" in
		login_accepted) login=1;;
		online)
			if [ "$alerted" = 1 ]; then title='上游已恢复联网'; event=online
			elif [ "$login" = 1 ]; then title='上游登录成功'; event=online
			elif [ "$group" = online ] && [ -n "$account" ] && [ -n "$old_account" ] && [ "$account" != "$old_account" ]; then
				title='上游账号已切换'; event=online
			fi
			group=online; since=0; login=0; alerted=0
			# Drop a warning which could not be sent while the router was offline.
			if [ "$event" = online ]; then sequence=$((sequence + 1)); rm -f "$directory/pending.json"; fi
			;;
		logged_out)
			group=idle; since=0; login=0; alerted=0; sequence=$((sequence + 1))
			rm -f "$directory/pending.json";;
		busy|offline_suspected) ;;
		waiting_interface|blocked|portal_not_ready|portal_not_found|request_failed|auth_rejected|no_account|account_busy|authenticated_limited|probe_uncertain|logout_failed|cooldown)
			if [ "$group" != problem ] || [ "$since" -eq 0 ] || [ "$since" -gt "$now" ]; then since="$now"; fi
			group=problem
			case "$state" in auth_rejected|no_account|blocked|logout_failed) immediate=1;; esac
			if [ "$immediate" = 1 ] || [ "$((now - since))" -ge "$CFG_PUSHPLUS_DELAY" ]; then
				event=failure; title='上游连接异常'
			fi
			;;
		*) return 0;;
	esac
	[ -n "$account" ] || account="$old_account"
	case "$event" in
		online) [ "$CFG_PUSHPLUS_ONLINE" = 1 ] || event='';;
		failure) [ "$CFG_PUSHPLUS_FAILURE" = 1 ] || event='';;
	esac
	if [ -n "$event" ] && { [ "$last_event" != "$event:$account" ] || [ "$now" -lt "$last_time" ] || [ "$((now - last_time))" -ge "$CFG_PUSHPLUS_INTERVAL" ]; }; then
		sequence=$((sequence + 1)); last_event="$event:$account"; last_time="$now"
		[ "$event" != failure ] || alerted=1
		json_init; json_add_int sequence "$sequence"
		json_add_string title "BJUT 路由器 · $title"
		json_add_string content "$(printf '上游：%s（%s）\n认证方式：%s\n账号：%s\n状态：%s\nIPv4：%s；IPv6：%s\n时间：%s' \
			"$CFG_NETWORK" "${DEVICE:-未分配}" "$(protocol_name "${protocol:-auto}")" "${account:-未登录}" "$message" \
			"$PROBE4" "$PROBE6" "$(date '+%Y-%m-%d %H:%M:%S')")"
		temporary="$directory/pending.$$"
		json_dump >"$temporary" && mv -f "$temporary" "$directory/pending.json"
	fi
	json_init; json_add_string group "$group"; json_add_string account "$account"
	json_add_int since "$since"; json_add_int login "$login"; json_add_int alerted "$alerted"
	json_add_string last_event "$last_event"; json_add_int last_time "$last_time"; json_add_int sequence "$sequence"
	temporary="$directory/state.$$"
	json_dump >"$temporary" && mv -f "$temporary" "$directory/state.json"
	pushplus_start_sender "$directory" "$now"
	pushplus_start_sender "$STATE_DIR/pushplus/.test" "$now"
	set +f
	for temporary in "$STATE_DIR"/pushplus/.billing-*; do [ ! -d "$temporary" ] || pushplus_start_sender "$temporary" "$now"; done
)

pushplus_queue_custom() (
	trap - 0 1 2 15
	pushplus_ready || return 0
	local directory="$STATE_DIR/pushplus/$1" now notified sequence
	case "$1" in .billing-*) ;; *) return 1;; esac
	case "$1" in *[!A-Za-z0-9_.-]*) return 1;; esac
	now="$(date +%s)"; notified="$(cat "$directory/notified" 2>/dev/null)"
	is_uint "$notified" && [ "$now" -ge "$notified" ] && [ "$((now-notified))" -lt 86400 ] && return 0
	mkdir -p "$directory" || return 1
	sequence="$now"; . "$JSHN_SH"; json_init
	json_add_int sequence "$sequence"; json_add_string title "BJUT 路由器 · $2"; json_add_string content "$3"
	json_dump >"$directory/pending.json"
	json_init; json_add_int sequence "$sequence"; json_dump >"$directory/state.json"
	printf '%s' "$now" >"$directory/notified"
	pushplus_start_sender "$directory" "$now"
)

pushplus_queue_test() (
	trap - 0 1 2 15
	pushplus_ready || return 1
	local directory="$STATE_DIR/pushplus/.test" now attempted='' attempt_sequence='' sequence temporary
	now="$(date +%s)"
	mkdir -p "$directory" || return 1
	[ ! -r "$directory/attempt" ] || read -r attempt_sequence attempted <"$directory/attempt"
	if is_uint "$attempted" && [ "$now" -ge "$attempted" ] && [ "$((now - attempted))" -lt 60 ]; then return 2; fi
	sequence="$now"
	. "$JSHN_SH"
	json_init; json_add_int sequence "$sequence"
	json_add_string title 'BJUT 路由器 · 测试消息'
	json_add_string content 'PushPlus 消息推送已配置。这是一条测试消息。'
	temporary="$directory/pending.$$"
	json_dump >"$temporary" && mv -f "$temporary" "$directory/pending.json" || return 1
	json_init; json_add_int sequence "$sequence"
	json_dump >"$directory/state.json" || return 1
	pushplus_start_sender "$directory" "$now"
)
