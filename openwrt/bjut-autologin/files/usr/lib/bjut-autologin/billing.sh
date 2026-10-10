#!/bin/sh
# SPDX-License-Identifier: MIT
# Billing cookies and captcha state are isolated by administrator/uplink/account.

billing_progress() {
	local state="$1" percent="$2" message="$3" tmp="$BILLING_JOB/result.json.$$"
	. "$JSHN_SH"
	json_init
	json_add_string state "$state"
	json_add_int percent "$percent"
	json_add_string message "$message"
	json_dump >"$tmp" && mv -f "$tmp" "$BILLING_JOB/result.json"
}

billing_normalize_path() {
	case "$1" in
		http://jfself.bjut.edu.cn/Self/*) printf '%s' "${1#http://jfself.bjut.edu.cn}" ;;
		http://172.21.0.16/Self/*|https://172.21.0.16/Self/*) value="${1#*://172.21.0.16}"; printf '%s' "$value" ;;
		*) printf '%s' "$1" ;;
	esac
}

billing_valid_path() {
	case "$1" in
		/Self/*) ;;
		https://jfself.bjut.edu.cn/Self/*) ;;
		*) return 1 ;;
	esac
	case "$1" in *'"'*|*'\'*|*' '*|*'
'*|*'..'*|*'#'*) return 1 ;; esac
	[ "${#1}" -le 2048 ]
}

billing_request() {
	local path="$1" data="${2:-}" url code location size rc method=GET count=0
	path="$(billing_normalize_path "$path")"
	billing_valid_path "$path" || return 1
	case "$path" in https://*) url="$path" ;; *) url="https://jfself.bjut.edu.cn$path" ;; esac
	[ -z "$data" ] || method=POST
	while [ "$count" -lt 6 ]; do
		set -- --silent --show-error --noproxy '*' --proxy '' --ipv4 \
			--proto '=https' --connect-timeout "$CFG_TIMEOUT" --max-time "$CFG_TIMEOUT" \
			--max-filesize 1048576 --resolve 'jfself.bjut.edu.cn:443:172.21.0.16' \
			--cookie "$BILLING_CACHE/cookies" --cookie-jar "$BILLING_CACHE/cookies" \
			--dump-header "$WORK_DIR/headers" --output "$WORK_DIR/billing-body" --write-out '%{http_code}' \
			--referer 'https://jfself.bjut.edu.cn/Self/login/' --user-agent "BJUT-Auto-Login-OpenWrt/$VERSION"
		if [ "$method" = POST ]; then
			set -- "$@" --header 'Content-Type: application/x-www-form-urlencoded' --header 'Origin: https://jfself.bjut.edu.cn'
		fi
		code="$( { printf 'url = "%s"\n' "$url"; [ "$method" != POST ] || printf 'data = "%s"\n' "$data"; } |
			bound_curl ipv4 "$@" --config - 2>"$WORK_DIR/curl-error")"
		rc=$?
		[ "$rc" = 0 ] || return 1
		size="$(wc -c <"$WORK_DIR/billing-body" | tr -d '[:space:]')"
		is_uint "$size" && [ "$size" -le 1048576 ] || return 1
		case "$code" in
			2[0-9][0-9]) return 0 ;;
			301|302|303)
				location="$(sed -n 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*//p' "$WORK_DIR/headers" | tr -d '\r' | tail -n 1)"
				location="$(billing_normalize_path "$location")"
				billing_valid_path "$location" || return 1
				case "$location" in https://*) url="$location" ;; *) url="https://jfself.bjut.edu.cn$location" ;; esac
				method=GET; data="" ;;
			# Never replay a password after a 307/308 response.
			*) return 1 ;;
		esac
		count=$((count + 1))
	done
	return 1
}

billing_extract() {
	"${BJUT_HTML:-/usr/libexec/bjut-html}" "$@" <"$WORK_DIR/billing-body"
}

billing_warm_assets() {
	local path asset_path
	# Use the saved login page: each response overwrites the network body.
	"${BJUT_HTML:-/usr/libexec/bjut-html}" assets <"$BILLING_CACHE/login.html" >"$WORK_DIR/login-assets"
	while IFS= read -r path; do
		path="$(billing_normalize_path "$path")"
		case "$path" in
			/Self/*|https://jfself.bjut.edu.cn/Self/*) ;;
			./*) path="/Self/login/${path#./}" ;;
			*[!a-zA-Z0-9_./?=\&%-]*) continue ;;
			*://*|//*|'') continue ;;
			*) path="/Self/login/$path" ;;
		esac
		asset_path="${path%%\?*}"
		case "$asset_path" in *.js|*.css) billing_request "$path" || true ;; esac
	done <"$WORK_DIR/login-assets"
}

billing_captcha_image() {
	local mime
	billing_request "/Self/login/randomCode?t=$(date +%s)" || return 1
	mime="$(sed -n 's/^[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Tt][Yy][Pp][Ee]:[[:space:]]*//p' "$WORK_DIR/headers" | tr -d '\r' | cut -d ';' -f1 | tail -n 1)"
	case "$mime" in image/png|image/jpeg|image/gif|image/webp) ;; *) return 1 ;; esac
	[ "$(wc -c <"$WORK_DIR/billing-body" | tr -d '[:space:]')" -le 131072 ] || return 1
	BILLING_IMAGE="data:$mime;base64,$(base64 <"$WORK_DIR/billing-body" | tr -d '\n')"
}

billing_need_captcha() {
	billing_captcha_image || { billing_progress error 100 "验证码图片加载失败，请刷新后重试"; return 1; }
	. "$JSHN_SH"
	json_init
	json_add_string state captcha
	json_add_int percent 40
	json_add_string message "请填写计费系统验证码"
	json_add_string image "$BILLING_IMAGE"
	json_dump >"$BILLING_JOB/result.json.$$" && mv -f "$BILLING_JOB/result.json.$$" "$BILLING_JOB/result.json"
}

billing_publish_overview() {
	local user actual status balance flow package
	user="$(billing_extract user-json)" || return 1
	actual="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.userName' 2>/dev/null)"
	[ "$actual" = "$BILLING_ACCOUNT" ] || return 1
	balance="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.leftMoney' 2>/dev/null)"
	flow="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.leftFlow' 2>/dev/null)"
	package="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.serviceDefault.defaultName' 2>/dev/null)"
	status="$(billing_extract status)"
	# Only allowlisted account metrics are returned. In particular the embedded
	# dashboard userPassword field never leaves the worker.
	. "$JSHN_SH"; json_init
	json_add_string state ready; json_add_int percent 100
	json_add_string message "计费数据已更新"
	json_add_string account "$actual"; json_add_string uplink "$UPLINK_ID"
	json_add_string balance "$balance"; json_add_string remainingFlow "$flow"
	json_add_string accountStatus "$status"; json_add_string package "$package"
	json_add_int updatedAt "$(date +%s)"
	json_dump >"$BILLING_JOB/overview.json"
	# The UI can show the verified overview while the optional session module
	# is still loading; one unavailable endpoint cannot hide the balance.
	sed 's/"state"[[:space:]]*:[[:space:]]*"ready"/"state":"loading"/;s/"percent"[[:space:]]*:[[:space:]]*100/"percent":85/;s/"message"[[:space:]]*:[[:space:]]*"计费数据已更新"/"message":"正在读取在线设备"/' "$BILLING_JOB/overview.json" >"$BILLING_JOB/result.json.$$" && mv -f "$BILLING_JOB/result.json.$$" "$BILLING_JOB/result.json"
	rm -f "$BILLING_JOB/online.json"
	if billing_request /Self/dashboard/getOnlineList; then
		# An HTTP-200 login page/error object is not an empty session list.
		if "$JSONFILTER_BIN" -i "$WORK_DIR/billing-body" -e '@' >"$BILLING_JOB/online.json" 2>/dev/null; then
			case "$(tr -d '[:space:]' <"$BILLING_JOB/online.json")" in
				'['*|'{'*'"rows":['*|'{'*'"data":['*) ;;
				*) rm -f "$BILLING_JOB/online.json" ;;
			esac
		else rm -f "$BILLING_JOB/online.json"; fi
	fi
	cp "$BILLING_JOB/overview.json" "$BILLING_JOB/result.json.$$" && mv -f "$BILLING_JOB/result.json.$$" "$BILLING_JOB/result.json"

}

billing_worker() {
	local ticket="$1" uplink account_id action code checkcode needs action_path password signature current cache_pid
	BILLING_JOB="$STATE_DIR/billing/$ticket"
	[ -s "$BILLING_JOB/request.json" ] || return 1
	uplink="$(json_file_value "$BILLING_JOB/request.json" '@.uplink')"
	account_id="$(json_file_value "$BILLING_JOB/request.json" '@.account')"
	action="$(json_file_value "$BILLING_JOB/request.json" '@.action')"
	code="$(json_file_value "$BILLING_JOB/request.json" '@.code')"
	load_configuration && select_uplink "$uplink" || return 1
	case " $ACCOUNT_SECTIONS " in *" $account_id "*) ;; *) billing_progress error 100 "请先选择已保存的账号"; return 1 ;; esac
	config_get BILLING_ACCOUNT "$account_id" username ""
	config_get password "$account_id" password ""
	[ -n "$BILLING_ACCOUNT" ] && [ -n "$password" ] || { billing_progress error 100 "该账号没有已保存密码"; return 1; }
	read_network_identity || { billing_progress error 100 "所选上游尚未取得校园网地址"; return 1; }
	prepare_work_dir || return 1
	ensure_uplink_routes
	sync_mwan_rules || true
	signature="$(printf '%s\n' "$UPLINK_ID" "$DEVICE" "$LOCAL_IPV4" "$BILLING_ACCOUNT" "$password" | sha256sum | awk '{print $1}')"
	BILLING_CACHE="$STATE_DIR/billing-cache/$(cat "$BILLING_JOB/owner")-$signature"
	mkdir -p "$BILLING_CACHE"
	if ! mkdir "$BILLING_CACHE/lock" 2>/dev/null; then
		cache_pid="$(cat "$BILLING_CACHE/lock/pid" 2>/dev/null)"
		if is_uint "$cache_pid" && kill -0 "$cache_pid" 2>/dev/null; then
			billing_progress error 100 "此账号正在查询，请稍后刷新"; return 1
		fi
		rm -rf "$BILLING_CACHE/lock"; mkdir "$BILLING_CACHE/lock" || return 1
	fi
	printf '%s' "$$" >"$BILLING_CACHE/lock/pid"
	CACHE_LOCK="$BILLING_CACHE/lock"
	printf '%s' "$(date +%s)" >"$BILLING_CACHE/created"
	current="$(cat "$BILLING_CACHE/context" 2>/dev/null)"
	if [ "$signature" != "$current" ]; then
		rm -f "$BILLING_CACHE/cookies" "$BILLING_CACHE/login.html"
		code=""
		printf '%s' "$signature" >"$BILLING_CACHE/context"
	fi
	if [ "$action" = refresh_captcha ] && [ -s "$BILLING_CACHE/login.html" ]; then
		billing_need_captcha; return $?
	fi
	if [ "$action" = captcha ] && [ -s "$BILLING_CACHE/login.html" ]; then
		cp "$BILLING_CACHE/login.html" "$WORK_DIR/billing-body"
	else
		billing_progress loading 10 "正在连接计费系统"
		billing_request '/Self/login/?302=LI' || { billing_progress error 100 "无法通过所选上游访问计费系统"; return 1; }
		if billing_publish_overview; then return 0; fi
	fi
	checkcode="$(billing_extract input checkcode)" || { billing_progress error 100 "计费登录页发生变化，请更新后重试"; return 1; }
	case "$checkcode" in ''|*[!0-9]*) billing_progress error 100 "计费登录页格式异常"; return 1 ;; esac
	[ "${#checkcode}" -le 4 ] || return 1
	needs="$(billing_extract captcha)" || { billing_progress error 100 "无法确定验证码状态，请重试"; return 1; }
	action_path="$(billing_extract action)" || return 1
	action_path="$(billing_normalize_path "$action_path")"
	case "$action_path" in /Self/login/verify|/Self/login/verify\;jsessionid=*|https://jfself.bjut.edu.cn/Self/login/verify*) ;; *) billing_progress error 100 "计费登录地址不受支持"; return 1 ;; esac
	cp "$WORK_DIR/billing-body" "$BILLING_CACHE/login.html"
	[ "$action" = captcha ] || billing_warm_assets
	if [ "$needs" = 1 ] && [ -z "$code" ]; then billing_need_captcha; return $?; fi
	if [ -z "$code" ]; then
		# The ordinary login requires the same session-local randomCode warmup.
		billing_request "/Self/login/randomCode?t=$(date +%s)" || { billing_progress error 100 "计费系统尚未就绪，请重试"; return 1; }
	fi
	billing_request "/Self/login/getBrandInfo?t=$(date +%s)" || true
	billing_progress loading 60 "正在登录所选账号"
	checkcode="checkcode=$(urlencode "$checkcode")&account=$(urlencode "$BILLING_ACCOUNT")&password=$(urlencode "$password")&code=$(urlencode "$code")"
	password=""
	billing_request "$action_path" "$checkcode" || { billing_progress error 100 "计费登录未完成，请重试"; return 1; }
	checkcode=""
	if grep -q '账号或密码出现错误\|账号或密码错误' "$WORK_DIR/billing-body"; then
		billing_progress error 100 "账号或密码错误"; return 1
	fi
	billing_progress loading 85 "正在读取用量与在线设备"
	if billing_publish_overview; then return 0; fi
	needs="$(billing_extract captcha)" || needs=0
	if [ "$needs" = 1 ]; then
		cp "$WORK_DIR/billing-body" "$BILLING_CACHE/login.html"
		billing_need_captcha; return $?
	fi
	billing_progress error 100 "计费系统未确认登录，请刷新后重试"
	return 1
}
