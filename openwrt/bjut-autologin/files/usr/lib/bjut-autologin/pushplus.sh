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

pushplus_safe_http() {
	case "$1" in [0-9][0-9][0-9]) printf '%s' "$1";; *) printf '000';; esac
}

pushplus_safe_code() {
	case "$1" in
		''|*[!0-9-]*) return 0;;
		-*) case "${1#-}" in ''|*[!0-9]*) return 0;; esac;;
	esac
	[ "${#1}" -le 8 ] && printf '%s' "$1"
}

pushplus_write_status() (
	trap - 0 1 2 15
	local directory="$1" state="$2" sequence="$3" now="$4" http="$5" code="$6" message="$7" temporary
	mkdir -p "$directory" || return 1
	is_uint "$sequence" || sequence=0
	is_uint "$now" || now="$(date +%s)"
	. "$JSHN_SH"
	json_init
	json_add_string state "$state"
	json_add_int sequence "$sequence"
	json_add_int updatedAt "$now"
	json_add_string httpStatus "$http"
	json_add_string apiCode "$code"
	json_add_int delivered 0
	json_add_string deliverySemantics accepted_not_delivered
	json_add_string message "$message"
	temporary="$directory/status.$$"
	json_dump >"$temporary" && mv -f "$temporary" "$directory/status.json"
)

pushplus_test_status() (
	trap - 0 1 2 15
	local directory="$STATE_DIR/pushplus/.test" status_file="$STATE_DIR/pushplus/.test/status.json"
	local state=idle sequence=0 updated_at=0 raw_http="" http="" code="" message=""
	local pending_seq="" attempt_seq="" attempted=0 now cooldown=0 pending=0 enabled=0 configured=0
	now="$(date +%s)"
	[ "${CFG_PUSHPLUS_ENABLED:-0}" != 1 ] || enabled=1
	if [ -n "${CFG_PUSHPLUS_TOKEN:-}" ] && valid_pushplus_token "$CFG_PUSHPLUS_TOKEN"; then configured=1; fi
	if [ -s "$status_file" ]; then
		state="$(json_file_value "$status_file" '@.state')"
		sequence="$(json_file_value "$status_file" '@.sequence')"
		updated_at="$(json_file_value "$status_file" '@.updatedAt')"
		raw_http="$(json_file_value "$status_file" '@.httpStatus')"
		[ -z "$raw_http" ] || http="$(pushplus_safe_http "$raw_http")"
		code="$(pushplus_safe_code "$(json_file_value "$status_file" '@.apiCode')")"
		message="$(json_file_value "$status_file" '@.message')"
	fi
	case "$state" in queued|accepted|error) ;; *) state=idle;; esac
	is_uint "$sequence" || sequence=0
	is_uint "$updated_at" || updated_at=0
	if [ -s "$directory/pending.json" ] || [ -d "$directory/sending" ]; then
		pending=1
		[ ! -s "$directory/pending.json" ] || pending_seq="$(json_file_value "$directory/pending.json" '@.sequence')"
		[ -n "$pending_seq" ] || [ ! -s "$directory/sending/message.json" ] ||
			pending_seq="$(json_file_value "$directory/sending/message.json" '@.sequence')"
		if [ "$state" = idle ] || { is_uint "$pending_seq" && [ "$pending_seq" -gt "$sequence" ]; }; then
			state=queued
			is_uint "$pending_seq" && sequence="$pending_seq"
			[ "$updated_at" -gt 0 ] || updated_at="$now"
			http=""; code=""
			message='测试消息排队发送中，等待后台连接 PushPlus。'
		fi
	fi
	[ ! -r "$directory/attempt" ] || read -r attempt_seq attempted <"$directory/attempt"
	if is_uint "$attempted" && [ "$now" -ge "$attempted" ] && [ "$((now - attempted))" -lt 60 ]; then
		cooldown="$((60 - (now - attempted)))"
	fi
	if [ -z "$message" ]; then
		case "$state" in
			queued) message='测试消息排队发送中，等待后台连接 PushPlus。';;
			accepted) message='PushPlus 已受理（HTTP 200 / 业务码 200）；平台异步投递，已受理不等于已送达。';;
			error) message="推送请求失败（HTTP ${http:-000} / 业务码 ${code:-未知}），将在冷却后重试。";;
			*)
				if [ "$enabled" = 1 ] && [ "$configured" = 1 ]; then
					message='尚未发送测试消息；点击测试推送后可查看排队、HTTP/业务码或受理状态。'
				else
					message='请先启用 PushPlus 消息推送并保存有效令牌。'
				fi
				;;
		esac
	fi
	. "$JSHN_SH"
	json_init
	json_add_string state "$state"
	json_add_int enabled "$enabled"
	json_add_int configured "$configured"
	json_add_int sequence "$sequence"
	json_add_int updatedAt "$updated_at"
	json_add_string httpStatus "$http"
	json_add_string apiCode "$code"
	json_add_int pending "$pending"
	json_add_int cooldownRemaining "$cooldown"
	json_add_int delivered 0
	json_add_string deliverySemantics accepted_not_delivered
	json_add_string message "$message"
	json_dump
)

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
	local directory="$1" now="$2" job="$1/sending/message.json" sequence title content http code safe_http safe_code
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
	safe_http="$(pushplus_safe_http "$http")"
	safe_code="$(pushplus_safe_code "$code")"
	if [ "$safe_http" = 200 ] && [ "$safe_code" = 200 ]; then
		# PushPlus is asynchronous: code=200 only acknowledges receipt.
		if [ "$(json_file_value "$directory/state.json" '@.sequence')" = "$sequence" ]; then
			pushplus_write_status "$directory" accepted "$sequence" "$now" "$safe_http" "$safe_code" \
				'PushPlus 已受理（HTTP 200 / 业务码 200）；平台异步投递，已受理不等于已送达。'
		fi
		log_message info 'PushPlus 已受理消息'
	else
		log_message warning "PushPlus 请求未成功（HTTP $safe_http / 业务码 ${safe_code:-未知}），将稍后重试"
		# Never restore an old failure after a newer event or manual logout.
		if [ "$(json_file_value "$directory/state.json" '@.sequence')" = "$sequence" ]; then
			ln "$job" "$directory/pending.json" 2>/dev/null || true
			pushplus_write_status "$directory" error "$sequence" "$now" "$safe_http" "$safe_code" \
				"推送请求失败（HTTP $safe_http / 业务码 ${safe_code:-未知}），将在冷却后重试。"
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
	pushplus_write_status "$directory" queued "$sequence" "$now" '' '' '测试消息排队发送中，等待后台连接 PushPlus。'
	pushplus_start_sender "$directory" "$now"
)
