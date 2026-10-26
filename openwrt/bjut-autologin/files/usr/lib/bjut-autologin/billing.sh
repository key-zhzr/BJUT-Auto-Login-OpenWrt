#!/bin/sh
# SPDX-License-Identifier: MIT
# Billing cookies and captcha state are isolated by administrator/uplink/account.

billing_progress() {
	local state="$1" percent="$2" message="$3" tmp="${BILLING_OUTPUT:-$BILLING_JOB/result.json}.$$"
	if [ "${BILLING_MODULE:-}" = center ] && [ -z "${BILLING_OUTPUT:-}" ] && [ "$state" = loading ];then percent=$((percent / 2));fi
	. "$JSHN_SH"
	json_init
	json_add_string state "$state"
	json_add_int percent "$percent"
	json_add_string message "$message"
	json_dump >"$tmp" && mv -f "$tmp" "${BILLING_OUTPUT:-$BILLING_JOB/result.json}"
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
			--referer "${BILLING_REFERER:-https://jfself.bjut.edu.cn/Self/login/}" --user-agent "BJUT-Auto-Login-OpenWrt/$VERSION"
		if [ "$method" = POST ]; then
			set -- "$@" --header 'Content-Type: application/x-www-form-urlencoded' --header 'Origin: https://jfself.bjut.edu.cn'
		fi
		[ "${BILLING_AJAX:-0}" != 1 ] || set -- "$@" --header 'X-Requested-With: XMLHttpRequest' --header 'Accept: application/json,text/plain,*/*;q=0.8'
		code="$( { printf 'url = "%s"\n' "$url"; [ "$method" != POST ] || printf 'data = "%s"\n' "$data"; } |
			bound_curl ipv4 "$@" --config - 2>"$WORK_DIR/curl-error")"
		rc=$?
		[ "$rc" = 0 ] || return 1
		size="$(wc -c <"$WORK_DIR/billing-body" | tr -d ' \011\012\015')"
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
	[ "$(wc -c <"$WORK_DIR/billing-body" | tr -d ' \011\012\015')" -le 131072 ] || return 1
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
	local user actual status balance flow package used total balance_text flow_text used_text total_text reason detail cycle percent=85 unlimited=0
	user="$(billing_extract user-json)" || return 1
	actual="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.userName' 2>/dev/null)"
	case "$actual" in ''|*[!A-Za-z0-9_@.,-]*) return 1 ;; esac
	[ "${#actual}" -le 256 ] || return 1
	[ "${BILLING_CURRENT:-0}" != 1 ] || BILLING_ACCOUNT="$actual"
	[ "$actual" = "$BILLING_ACCOUNT" ] || return 1
	BILLING_VERIFIED=1
	cp "$WORK_DIR/billing-body" "$BILLING_JOB/dashboard.html"
	if [ -n "${BILLING_OPERATION:-}" ]; then
		[ "$actual" = "$(json_file_value "$BILLING_JOB/request.json" '@.expectedAccount')" ] || { billing_progress error 100 '认证账号已变化，未提交操作，请重新查询'; return 1; }
		billing_apply_action "$BILLING_OPERATION"; return $?
	fi
	if [ -n "${BILLING_MODULE:-}" ] && [ "$BILLING_MODULE" != center ]; then billing_module "$BILLING_MODULE"; return $?; fi
	# Same precedence and units as App parse_dashboard(): rendered dt metrics
	# first, embedded leftMoney/leftFlow (MB) only when the metric is absent.
	balance_text="$(billing_extract dashboard-metric '账户余额')"
	if [ -z "$balance_text" ]; then
		balance_text="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.leftMoney' 2>/dev/null | billing_number | awk 'NF{v=sprintf("%.4f",$0);sub(/0+$/,"",v);sub(/[.]$/,"",v);printf "%s",v}')"
	fi
	balance="$(printf '%s' "$balance_text" | billing_number)"
	case "$balance_text" in *元*) ;; *) [ -z "$balance" ] || balance_text="$balance 元";; esac
	flow_text="$(billing_extract dashboard-metric '可用流量')"
	[ -n "$flow_text" ] || flow_text="$(billing_extract dashboard-metric '剩余流量')"
	[ -n "$flow_text" ] || flow_text="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.leftFlow' 2>/dev/null | billing_number)"
	case "$flow_text:$(printf '%s' "$flow_text" | billing_number | awk '{if($0+0<0)printf "negative"}')" in *无限*|*不限*|*:negative) unlimited=1; flow=''; flow_text=无限;;
		*) flow="$(printf '%s' "$flow_text" | billing_flow_mb)"; [ -z "$flow" ] || flow_text="$(awk -v n="$flow" 'BEGIN{printf "%.2f GB",n/1024}')";; esac
	package="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.serviceDefault.defaultName' 2>/dev/null)"
	detail="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.serviceDefault.extend' 2>/dev/null)"
	account_record_plan "$actual" "$package"
	status="$(billing_extract status)"
	reason="$(printf '%s' "$user" | "$JSONFILTER_BIN" -e '@.stopReason' 2>/dev/null)"; [ "$status" != 正常 ] || reason=''
	cycle="$(billing_extract cycle)"
    if [ -n "${BILLING_RECORD_KIND:-}" ]; then billing_publish_records "$actual"; return $?; fi
    used_text="$(billing_extract dashboard-metric '已用流量')"; used="$(printf '%s' "$used_text" | billing_flow_mb)"
    total_text="$(billing_extract dashboard-metric '总流量')"; total="$(printf '%s' "$total_text" | billing_flow_mb)"
    if [ -z "$total" ] && [ -n "$used" ] && [ -n "$flow" ]; then total="$(awk -v left="$flow" -v used="$used" 'BEGIN {if(left+0>=0)printf "%.3f",left+used}')"; fi
	# Only allowlisted account metrics are returned. In particular the embedded
	# dashboard userPassword field never leaves the worker.
	. "$JSHN_SH"; json_init
	json_add_string state ready; json_add_int percent 100
	json_add_string message "计费数据已更新"
	json_add_string account "$actual"; json_add_string uplink "$UPLINK_ID"
	json_add_string access "${BILLING_ACCESS:-已保存账号}"
	json_add_string balance "$balance"; json_add_string remainingFlow "$flow"; json_add_string totalFlow "$total"; json_add_string usedFlow "$used"
	json_add_string balanceText "${balance_text:---}"; json_add_string remainingFlowText "${flow_text:---}"
	json_add_string usedFlowText "${used_text:---}"; json_add_int remainingFlowUnlimited "$unlimited"
	json_add_string statusReason "$reason"; json_add_string packageDetail "$detail"; json_add_string billingCycle "$cycle"
	json_add_array warnings
	[ -n "$balance_text" ] || json_add_string '' '控制台没有返回账户余额'
	[ -n "$flow_text" ] || json_add_string '' '控制台没有返回剩余流量'
	json_close_array
	json_add_string accountStatus "$status"; json_add_string package "$package"
	json_add_int updatedAt "$(date +%s)"
	json_dump >"$BILLING_JOB/overview.json"
	# The UI can show the verified overview while the optional session module
	# is still loading; one unavailable endpoint cannot hide the balance.
	[ "${BILLING_MODULE:-}" != center ] || percent=44
	sed 's/"state"[[:space:]]*:[[:space:]]*"ready"/"state":"loading"/;s/"percent"[[:space:]]*:[[:space:]]*100/"percent":'"$percent"'/;s/"message"[[:space:]]*:[[:space:]]*"计费数据已更新"/"message":"正在读取在线设备"/' "$BILLING_JOB/overview.json" >"$BILLING_JOB/result.json.$$" && mv -f "$BILLING_JOB/result.json.$$" "$BILLING_JOB/result.json"
	# The traffic worker prepares routes/session/dashboard ahead of the shared
	# minute boundary. Only the counter request waits; interactive jobs do not.
	if is_uint "${BJUT_TRAFFIC_SAMPLE_AT:-}";then
		local sample_now="$(date +%s)" sample_delay
		sample_delay=$((BJUT_TRAFFIC_SAMPLE_AT-sample_now))
		if [ "$sample_delay" -gt 0 ] && [ "$sample_delay" -le 60 ];then
			sleep "$sample_delay" & SLEEP_PID="$!";wait "$SLEEP_PID";SLEEP_PID=''
		fi
	fi
	rm -f "$BILLING_JOB/online.json"
	if billing_request /Self/dashboard/getOnlineList; then
		# An HTTP-200 login page/error object is not an empty session list.
		# Some portal versions return a literal null for an empty list, which
		# jsonfilter builds differ on accepting as a root value.
		billing_capture_online && date +%s >"$BILLING_JOB/online-at" || true
	fi
	if [ "${BILLING_MODULE:-}" = center ]; then billing_center_modules; else
	 cp "$BILLING_JOB/overview.json" "$BILLING_JOB/result.json.$$" && mv -f "$BILLING_JOB/result.json.$$" "$BILLING_JOB/result.json"
	fi

}

billing_current_session() {
	local url auth path query
	BILLING_SSO_ATTEMPTED=0
	# No password is sent to the gateway. Each request uses this uplink's own
	# physical source and the same TLS checks as the App's account discovery.
	url="https://lgn.bjut.edu.cn:802/eportal/portal/self?callback=726427262622&self_type=27&user_account=&user_password=&wlan_user_mac=&jsVersion=2238243824&program_index=79225954737327212323222f212e2723&page_index=755e577b7c4e27212323222f212e2320&encrypt=1&v=$(request_id)&lang=zh"
	lgn_request "$url" lgn.bjut.edu.cn 802 'https://lgn.bjut.edu.cn/' || return 1
	load_jsonp && [ "$(jsonp_value '@.result')" = 1 ] || return 1
	auth="$(jsonp_value '@.self_auth_url')"
	auth="$(billing_normalize_path "$auth")"
	billing_valid_path "$auth" || return 1
	case "$auth" in https://jfself.bjut.edu.cn/*) path="${auth#https://jfself.bjut.edu.cn}" ;; *) path="$auth" ;; esac
	case "$path" in /Self/login/eportalLogin\?*) ;; *) return 1 ;; esac
	query="${path#*\?}"
	# Reject unsigned/foreign destinations before sending the session token.
	for key in account timestamp sign; do
		case "&$query&" in *"&$key="[!\&]*'&'*) ;; *) return 1 ;; esac
	done
	BILLING_SSO_ATTEMPTED=1
	billing_request "$path" || return 1
	BILLING_ACCESS="当前认证账号"
	billing_publish_overview
}

billing_collect_expired() (
	local now="$1" old created
	set +f
	for old in "$STATE_DIR"/billing/* "$STATE_DIR"/billing-cache/*; do
		[ -d "$old" ] || continue
		# Active queries may outlive their creation time; never delete their lock.
		[ ! -d "$old/lock" ] || continue
		created="$(cat "$old/created" 2>/dev/null)"
		is_uint "$created" && [ "$((now - created))" -gt 600 ] && rm -rf -- "$old"
	done
)

billing_worker() {
	local ticket="$1" uplink account_id action code checkcode needs action_path password signature current cache_pid section enabled order saved_account observed_account candidate_account
	BILLING_JOB="$STATE_DIR/billing/$ticket"
	[ -s "$BILLING_JOB/request.json" ] || return 1
	uplink="$(json_file_value "$BILLING_JOB/request.json" '@.uplink')"
	account_id="$(json_file_value "$BILLING_JOB/request.json" '@.account')"
	action="$(json_file_value "$BILLING_JOB/request.json" '@.action')"
    BILLING_RECORD_KIND="$(json_file_value "$BILLING_JOB/request.json" '@.kind')"
	BILLING_MODULE="$(json_file_value "$BILLING_JOB/request.json" '@.module')"
	BILLING_OPERATION="$(json_file_value "$BILLING_JOB/request.json" '@.operation')"
	code="$(json_file_value "$BILLING_JOB/request.json" '@.code')"
	load_configuration && select_uplink "$uplink" || return 1
	BILLING_CURRENT=0; BILLING_VERIFIED=0; BILLING_ACCESS="已保存账号"; BILLING_ACCOUNT=""; password=""
	if [ "$account_id" = current ]; then
		BILLING_CURRENT=1
		# A failed SSO must not silently query the first enabled account. Only
		# the last observed account on this source is a valid password fallback.
		observed_account="$(json_file_value "$STATE_FILE" '@.account')"
		for section in $ACCOUNT_SECTIONS; do
			config_get candidate_account "$section" username ""
			[ -n "$observed_account" ] && [ "${candidate_account%@campus}" = "${observed_account%@campus}" ] || continue
			BILLING_ACCOUNT="$candidate_account"
			config_get password "$section" password ""
			[ -z "$BILLING_ACCOUNT" ] || [ -z "$password" ] || break
		done
	else
		case " $ACCOUNT_SECTIONS " in *" $account_id "*) ;; *) billing_progress error 100 "请先选择已保存的账号"; return 1 ;; esac
		config_get BILLING_ACCOUNT "$account_id" username ""
		config_get password "$account_id" password ""
	fi
	saved_account="$BILLING_ACCOUNT"
	read_network_identity || { billing_progress error 100 "所选上游尚未取得校园网地址"; return 1; }
	prepare_work_dir || return 1
	ensure_uplink_routes || { billing_progress error 100 '出口路由正在被其他上游更新，请稍后刷新'; return 1; }
	sync_mwan_rules || true
	signature="$(printf '%s\n' "$UPLINK_ID" "$DEVICE" "$LOCAL_IPV4" "$account_id" "$BILLING_ACCOUNT" "$password" | sha256sum | awk '{print $1}')"
	[ "${#signature}" = 64 ] || { billing_progress error 100 "请重新安装路由端以补齐所需组件"; return 1; }
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
		# Reuse this account's verified cookie jar on the same physical source.
		# The cache signature includes uplink/address/account/password; a fresh
		# dashboard must still confirm the selected account before any action.
		if [ "$account_id" != current ] && [ "$signature" = "$current" ] && [ -s "$BILLING_CACHE/cookies" ]; then
			BILLING_CURRENT=0
			billing_progress loading 10 '正在刷新计费会话'
			if billing_request /Self/dashboard && billing_publish_overview;then password='';return 0;fi
			[ -z "$BILLING_OPERATION" ] || [ "$BILLING_VERIFIED" != 1 ] || return 1
		fi
		billing_progress loading 10 "正在查询当前认证账号"
		if billing_current_session; then password=""; return 0; fi
        [ -z "$BILLING_OPERATION" ] || [ "$BILLING_VERIFIED" != 1 ] || return 1
		# A different selected account must never inherit the current account's
		# cookies. An unavailable discovery must not reuse an old current login.
		if [ "$account_id" = current ] || [ "$BILLING_SSO_ATTEMPTED" = 1 ]; then rm -f "$BILLING_CACHE/cookies"; fi
		BILLING_CURRENT=0; BILLING_ACCESS="已保存账号"
		BILLING_ACCOUNT="$saved_account"
		[ -n "$BILLING_ACCOUNT" ] && [ -n "$password" ] || { billing_progress error 100 "当前账号暂时无法查询，请选择已保存的账号"; return 1; }
		billing_progress loading 20 "正在连接计费系统"
		billing_request '/Self/login/?302=LI' || { billing_progress error 100 "无法通过所选上游访问计费系统"; return 1; }
		if billing_publish_overview; then return 0; fi
        [ -z "$BILLING_OPERATION" ] || [ "$BILLING_VERIFIED" != 1 ] || return 1
	fi
	BILLING_CURRENT=0; BILLING_ACCESS="已保存账号"
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
        [ -z "$BILLING_OPERATION" ] || [ "$BILLING_VERIFIED" != 1 ] || return 1
	needs="$(billing_extract captcha)" || needs=0
	if [ "$needs" = 1 ]; then
		cp "$WORK_DIR/billing-body" "$BILLING_CACHE/login.html"
		billing_need_captcha; return $?
	fi
	billing_progress error 100 "计费系统未确认登录，请刷新后重试"
	return 1
}


billing_flow_mb() {
 awk '{v=$0;if(v~/无限|不限/)exit;if(!match(v,/-?[0-9]+([.][0-9]+)?/))exit;n=substr(v,RSTART,RLENGTH)+0;if(n<0)exit;if(v~/[Tt][Bb]/)n*=1048576;else if(v~/[Gg][Bb]/)n*=1024;else if(v~/[Kk][Bb]/)n/=1024;printf "%.3f",n;exit}'
}

billing_number() { awk '{if(match($0,/-?[0-9]+([.][0-9]+)?/)){printf "%s",substr($0,RSTART,RLENGTH);exit}}'; }

billing_normalize_json() {
 local input="$1" output="$2" raw
 raw="$(cat "$input")"; raw="${raw#$(printf '\357\273\277')}"
 case "$(printf '%s' "$raw" | tr -d ' \011\012\015')" in ''|null) printf 'null' >"$output"; return 0;; esac
 printf '%s' "$raw" | "$JSONFILTER_BIN" -e '@' >"$output.unwrapped" 2>/dev/null || return 1
 case "$(tr -d ' \011\012\015' <"$output.unwrapped")" in null) printf 'null' >"$output"; return 0;; esac
 # jsonfilter unwraps a JSON string. Validate the nested document once, as App does.
 "$JSONFILTER_BIN" -i "$output.unwrapped" -e '@' >"$output" 2>/dev/null
}

billing_row_value() (
 local row="$1" wanted="$2" column="$3" value keys key lower type
 case "$row" in
  '['*) printf '%s' "$row" | "$JSONFILTER_BIN" -e "@[$column]" 2>/dev/null; return;;
  '{'*) ;;
  *) return 1;;
 esac
 # Most tables use the documented exact keys. Avoid loading an entire shell
 # JSON namespace for every scalar cell; retain typed validation for containers.
 value="$(printf '%s' "$row" | "$JSONFILTER_BIN" -e "@.$wanted" 2>/dev/null)"
 case "$value" in ''|'{'*|'['*) ;; *) printf '%s' "$value";return;;esac
 . "$JSHN_SH"; json_load "$row" && json_get_keys keys || return 1
 lower="$(printf '%s' "$wanted" | tr A-Z a-z)"
 for key in $keys; do
  if [ "$(printf '%s' "$key" | tr A-Z a-z)" = "$lower" ]; then
   case "$key" in *[!A-Za-z0-9_]*) return 1;; esac
   json_get_type type "$key"
   case "$type" in object|array) return 1;; null) printf '%s' '--';return;; esac
   printf '%s' "$row" | "$JSONFILTER_BIN" -e "@.$key" 2>/dev/null; return
  fi
 done
)

billing_capture_online() {
 local source="$BILLING_JOB/online.json" prefix='@' rows index=0 row id
 billing_normalize_json "$WORK_DIR/billing-body" "$source" || { rm -f "$source";return 1; }
 [ "$(cat "$source")" != null ] || printf '[]' >"$source"
 rows="$(json_file_value "$source" '@.rows')"
 case "$rows" in '['*) prefix='@.rows';; *) rows="$(json_file_value "$source" '@.data')";case "$rows" in '['*) prefix='@.data';; *) rows="$(cat "$source")";; esac;; esac
 case "$rows" in '['*) ;; *) rm -f "$source";return 1;; esac
 while [ "$index" -le 500 ]; do
  row="$(json_file_value "$source" "$prefix[$index]")";[ -n "$row" ] || return 0
  id="$(json_file_value "$source" "$prefix[$index].sessionId")"
  if [ "$index" = 500 ] || [ -z "$id" ] || [ "$id" = null ] || [ "${#id}" -gt 256 ];then rm -f "$source";return 1;fi
  index=$((index+1))
 done
}

billing_format_mac() {
 local value compact
 value="$1"; compact="$(printf '%s' "$value" | tr -cd '0-9a-fA-F' | tr a-f A-F)"
 if [ "${#compact}" = 12 ]; then printf '%s' "$compact" | sed 's/../&-/g;s/-$//'; else printf '%s' "$value"; fi
}

billing_validate_records() {
 local kind="$1" start="$2" end="$3" year="$4" page="$5" first last
 case "$kind" in usage|payments|operations)
  first="$(printf '%s' "$start" | "$CODEC_BIN" date-days)" && last="$(printf '%s' "$end" | "$CODEC_BIN" date-days)" || return 1
  [ "$last" -ge "$first" ] && [ "$((last-first))" -le 3660 ] || return 1;;
  monthly) is_uint "$year" && [ "$year" -ge 2000 ] && [ "$year" -le 2199 ] || return 1;;
  stopLogs|reopenLogs|packageLogs) ;;
  *) return 1;;
 esac
 is_uint "$page" && [ "$page" -ge 1 ] && [ "$page" -le 10000 ]
}

billing_record_spec() {
 case "$1" in
  usage) RECORD_PATH=/Self/bill/getUserOnlineLog; RECORD_PAGE=/Self/bill/userOnlineLog; RECORD_SORT=loginTime; RECORD_FIELDS='loginTime logoutTime time flow costMoney internetUpFlow internetDownFlow chinanetUpFlow chinanetDownFlow userIp userIp1 macAddress nasIp nasPort';;
  monthly) RECORD_PATH=/Self/bill/getMonthPay; RECORD_PAGE=/Self/bill/monthPay; RECORD_SORT=0; RECORD_FIELDS='startAt endAt package baseFee usageFee durationMinutes flowMb billedAt';;
  payments) RECORD_PATH=/Self/bill/getPayMent; RECORD_PAGE=/Self/bill/payMent; RECORD_SORT=0; RECORD_FIELDS='paidAt type amount terminal note';;
  operations) RECORD_PATH=/Self/bill/getOperatorLog; RECORD_PAGE=/Self/bill/operatorLog; RECORD_SORT=0; RECORD_FIELDS='operatedAt description terminal unused note';;
  stopLogs) RECORD_PATH=/Self/service/getStopLog; RECORD_PAGE=/Self/service/goStop; RECORD_SORT=''; RECORD_FIELDS='fldoperatedate fldoperateid fldadminid fldmemo';;
  reopenLogs) RECORD_PATH=/Self/service/goReopenLog; RECORD_PAGE=/Self/service/goReopen; RECORD_SORT=''; RECORD_FIELDS='fldoperatedate fldoperateid fldnewvalue fldadminid fldmemo';;
  packageLogs) RECORD_PATH=/Self/service/packageLog; RECORD_PAGE=/Self/service/package; RECORD_SORT=fldchangedate; RECORD_FIELDS='fldchangedate fldexcutedate flddefaultname1 flddefaultname2 fldstate fldstatedate fldextend';;
  *) return 1;;
 esac
}

billing_record_fetch() {
 local page="$1" start="$2" end="$3" year="$4" url prefix valid=0 expected
 url="$RECORD_PATH?pageSize=100&pageNumber=$page&searchText=&sortOrder=DESC&t=$(request_id)"
 [ -z "$RECORD_SORT" ] || url="$url&sortName=$RECORD_SORT"
 [ -z "$start" ] || url="$url&startTime=$start&endTime=$end"
 [ -z "$year" ] || url="$url&year=$year"
 billing_request "$url" || return 1
 RECORD_SOURCE="$WORK_DIR/records.json"; billing_normalize_json "$WORK_DIR/billing-body" "$RECORD_SOURCE" || return 1
 [ "$(cat "$RECORD_SOURCE")" != null ] || printf '{"rows":[],"total":0}' >"$RECORD_SOURCE"
 RECORD_PREFIX='@.rows'
 prefix="$(json_file_value "$RECORD_SOURCE" '@.rows')"; case "$prefix" in '['*) valid=1;; esac
 if [ "$valid" = 0 ]; then prefix="$(json_file_value "$RECORD_SOURCE" '@.data')"; case "$prefix" in '['*) RECORD_PREFIX='@.data'; valid=1;; esac; fi
 if [ "$valid" = 0 ]; then prefix="$(tr -d ' \011\012\015' <"$RECORD_SOURCE")"; case "$prefix" in '['*) RECORD_PREFIX='@'; valid=1;; esac; fi
 [ "$valid" = 1 ] || return 1
 RECORD_COUNT="$(json_file_value "$RECORD_SOURCE" '@.total')"
 if ! is_uint "$RECORD_COUNT"; then
  RECORD_COUNT=0; while [ "$RECORD_COUNT" -lt 100 ]; do [ -n "$(json_file_value "$RECORD_SOURCE" "$RECORD_PREFIX[$RECORD_COUNT]")" ] || break; RECORD_COUNT=$((RECORD_COUNT+1)); done
 fi
 [ "$RECORD_COUNT" -le 1000000 ] || return 1
 expected=$((RECORD_COUNT-(page-1)*100)); [ "$expected" -ge 0 ] || expected=0
 [ "$expected" -le 100 ] || expected=100
 [ "$expected" = 0 ] || [ -n "$(json_file_value "$RECORD_SOURCE" "$RECORD_PREFIX[$((expected-1))]")" ] || return 1
 [ -z "$(json_file_value "$RECORD_SOURCE" "$RECORD_PREFIX[$expected]")" ]
}

billing_summary_spec() {
 case "$BILLING_RECORD_KIND" in
  usage) printf '%s\n' 'COSTMONEY|计费金额(元)' 'COU|记录数' 'FLOW|使用流量(MB)' 'TIME|使用时长(分钟)';;
  monthly) printf '%s\n' 'USEBASEMONEY|基本月租(元)' 'USEDMONEY|时长/流量计费(元)' 'USETIME|使用时长(分钟)' 'USEFLOW|使用流量(MB)';;
  payments) printf '%s\n' 'MONEY|金额(元)';;
 esac
}

billing_summary_collect() {
 local key label summary value previous summed
 summary="$(json_file_value "$RECORD_SOURCE" '@.summary')"
 billing_summary_spec >"$WORK_DIR/summary-spec"
 while IFS='|' read -r key label;do
  [ -n "$key" ] || continue
  value="$(billing_row_value "$summary" "$key" 0)"
  if [ -z "$value" ];then
   [ "$RECORD_COUNT" = 0 ] || : >"$WORK_DIR/summary-$key-missing"
   continue
  fi
  previous="$(cat "$WORK_DIR/summary-$key" 2>/dev/null)"
  # Match App's decimal sums without accumulating binary fractional errors.
  summed="$(awk -v a="${previous:-0}" -v b="$value" 'function scaled(v, parts,n){if(v!~/^-?[0-9]+([.][0-9]+)?$/)return "bad";split(v,parts,".");if(length(parts[2])>6)return "bad";n=int(v)*1000000;return n+(v<0?-1:1)*(substr(parts[2]"000000",1,6)+0)} BEGIN{x=scaled(a);y=scaled(b);if(x=="bad"||y=="bad"||x+y>9000000000000000||x+y< -9000000000000000)exit 1;s=sprintf("%.6f",(x+y)/1000000);sub(/0+$/,"",s);sub(/[.]$/,"",s);printf "%s",s}')" && printf '%s' "$summed" >"$WORK_DIR/summary-$key" || : >"$WORK_DIR/summary-$key-missing"
 done <"$WORK_DIR/summary-spec"
}

billing_publish_records() {
 local actual="$1" start end year page first last cursor stop from to offset=0 total=0 page_from page_to page_index global index key value column row_position list row_bytes window_count formatted mac nas_ip nas_port access_method label
 start="$(json_file_value "$BILLING_JOB/request.json" '@.start_date')"; end="$(json_file_value "$BILLING_JOB/request.json" '@.end_date')"; year="$(json_file_value "$BILLING_JOB/request.json" '@.year')"; page="$(json_file_value "$BILLING_JOB/request.json" '@.page')"
 billing_validate_records "$BILLING_RECORD_KIND" "$start" "$end" "$year" "$page" && billing_record_spec "$BILLING_RECORD_KIND" || { billing_progress error 100 '记录查询内容无效'; return 1; }
 BILLING_REFERER="https://jfself.bjut.edu.cn$RECORD_PAGE"
 billing_request "$RECORD_PAGE" || { billing_progress error 100 '记录页面暂时不可用'; return 1; }
 first=0;last=0
 case "$BILLING_RECORD_KIND" in usage|payments|operations) first="$(printf '%s' "$start" | "$CODEC_BIN" date-days)";last="$(printf '%s' "$end" | "$CODEC_BIN" date-days)";; esac
 from=$(((page-1)*100));to=$((from+99));cursor="$last"
 list="$WORK_DIR/record-rows"; : >"$list"
 while [ "$cursor" -ge "$first" ]; do
  stop=$((cursor-59)); [ "$stop" -ge "$first" ] || stop="$first"
  start='';end=''
  case "$BILLING_RECORD_KIND" in usage|payments|operations) start="$(printf '%s' "$stop" | "$CODEC_BIN" days-date)";end="$(printf '%s' "$cursor" | "$CODEC_BIN" days-date)";; esac
  billing_progress loading "$((30+60*(last-cursor)/(last-first+1)))" '正在读取用量与账单'
  billing_record_fetch 1 "$start" "$end" "$year" || { billing_progress error 100 '记录查询失败，请稍后重试'; return 1; }
  billing_summary_collect
  window_count="$RECORD_COUNT";total=$((total+RECORD_COUNT));page_from=1;page_to=0
  if [ "$RECORD_COUNT" -gt 0 ] && [ "$to" -ge "$offset" ] && [ "$from" -lt "$((offset+RECORD_COUNT))" ]; then
   [ "$from" -le "$offset" ] || page_from=$(((from-offset)/100+1))
   page_to=$(((to-offset)/100+1));[ "$page_to" -le "$(((RECORD_COUNT+99)/100))" ] || page_to=$(((RECORD_COUNT+99)/100))
  fi
  page_index="$page_from"
  while [ "$page_index" -le "$page_to" ]; do
   [ "$page_index" = 1 ] || billing_record_fetch "$page_index" "$start" "$end" "$year" || { billing_progress error 100 '部分记录暂时无法查询'; return 1; }
   [ "$RECORD_COUNT" = "$window_count" ] || { billing_progress error 100 '查询期间记录发生变化，请重新查询'; return 1; }
   index=0
 while [ "$index" -lt 100 ]; do
    row_position="$RECORD_PREFIX[$index]"; row_bytes="$(json_file_value "$RECORD_SOURCE" "$row_position")"; [ -n "$row_bytes" ] || break
    global=$((offset+(page_index-1)*100+index))
    if [ "$global" -ge "$from" ] && [ "$global" -le "$to" ]; then
     json_init;json_add_array row;column=0;mac='';nas_ip='';nas_port=''
     for key in $RECORD_FIELDS; do
      case "$row_bytes" in '['*|'{'*) ;; *) billing_progress error 100 '记录包含无法识别的条目'; return 1;; esac
      value="$(billing_row_value "$row_bytes" "$key" "$column")"
      case "$key" in
       loginTime|logoutTime|startAt|endAt|billedAt|paidAt|operatedAt|fldoperatedate|fldchangedate|fldexcutedate|fldstatedate)
        case "$value" in ''|*[!0-9]*) ;; *)
         if [ "${#value}" -gt 10 ] && formatted="$(printf '%s' "$value" | "$CODEC_BIN" timestamp-date 2>/dev/null)"; then value="$formatted"; fi;;
        esac;;
      esac
      case "$key" in *mac*|*Mac*|*MAC*) value="$(billing_format_mac "$value")";; esac
      case "$key" in macAddress) mac="$value";;nasIp) nas_ip="$value";;nasPort) nas_port="$value";;esac
      if [ "$BILLING_RECORD_KIND" = usage ];then
       case "$key" in internetUpFlow|internetDownFlow|chinanetUpFlow|chinanetDownFlow|nasIp|nasPort) column=$((column+1));continue;;esac
      fi
      [ "${#value}" -le 512 ] || value='内容较长';json_add_string '' "$value";column=$((column+1))
     done
     if [ "$BILLING_RECORD_KIND" = usage ];then
      access_method=未知
      if [ "$mac:$nas_ip:$nas_port" = '00-00-00-00-00-00:0.0.0.0:0' ];then access_method='lgn（有线）'
      elif [ "$nas_ip" = 10.21.251.3 ];then access_method=bjut_wifi
      elif [ "$nas_ip" = 10.21.221.97 ];then access_method=bjut-sushe;fi
      json_add_string '' "$access_method"
     fi
     json_close_array;json_dump >>"$list"
    fi
    index=$((index+1))
   done
   page_index=$((page_index+1))
  done
  offset="$total";cursor=$((stop-1))
 done
 json_init;json_add_string state ready;json_add_int percent 100;json_add_string message '用量与账单已更新';json_add_string account "$actual";json_add_string kind "$BILLING_RECORD_KIND";json_add_int total "$total";json_add_int page "$page"
 json_add_array columns;for key in $RECORD_FIELDS;do
  if [ "$BILLING_RECORD_KIND" = usage ];then case "$key" in internetUpFlow|internetDownFlow|chinanetUpFlow|chinanetDownFlow|nasIp|nasPort) continue;;esac;fi
  json_add_string '' "$key"
 done
 [ "$BILLING_RECORD_KIND" != usage ] || json_add_string '' accessMethod
 json_close_array
 json_add_object summary
 billing_summary_spec >"$WORK_DIR/summary-spec"
 while IFS='|' read -r key label;do
  [ -s "$WORK_DIR/summary-$key" ] && [ ! -e "$WORK_DIR/summary-$key-missing" ] || continue
  json_add_string "$label" "$(cat "$WORK_DIR/summary-$key")"
 done <"$WORK_DIR/summary-spec"
 json_close_object
 # Rows were constructed exclusively from the selected columns, including for
 # positional server tables. Private fields and session identifiers stay local.
 json_dump >"$WORK_DIR/record-result"
 { sed 's/}[[:space:]]*$/,"rows":[/' "$WORK_DIR/record-result"; comma='';while IFS= read -r value;do printf '%s' "$comma";comma=,;printf '%s' "$value" | sed 's/^{[[:space:]]*"row"[[:space:]]*:[[:space:]]*//;s/}[[:space:]]*$//';done <"$list";printf ']}\n'; } >"$BILLING_JOB/result.json.$$" && mv -f "$BILLING_JOB/result.json.$$" "$BILLING_JOB/result.json"
}

. "$LIB_DIR/billing-services.sh"
