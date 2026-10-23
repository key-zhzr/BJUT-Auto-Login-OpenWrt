#!/bin/sh

if [ "$1" = --version ]; then printf 'curl %s mock\n' "${MOCK_CURL_VERSION:-8.19.0}"; exit 0; fi

state_dir="${MOCK_STATE_DIR:?}"
mkdir -p "$state_dir"
config="$(cat)"
url="$(printf '%s\n' "$config" | sed -n 's/^url = "\(.*\)"$/\1/p')"
output=""
pinned=0
interface=""
family=ipv4
headers=""
cookie_file=""
data="$(printf '%s\n' "$config" | sed -n 's/^data = "\(.*\)"$/\1/p')"
previous=""
for argument in "$@"; do
	case "$previous" in
		--output) output="$argument" ;;
		--interface) interface="$argument" ;;
		--dump-header) headers="$argument" ;;
		--cookie-jar) cookie_file="$argument" ;;
	esac
	[ "$argument" != "--ipv6" ] || family=ipv6
	[ "$argument" = "--pinnedpubkey" ] && pinned=1
	previous="$argument"
done
printf 'ARGS %s\n' "$*" >>"$state_dir/requests.log"
printf 'URL %s\n' "$url" >>"$state_dir/requests.log"
printf 'IFACE %s\n' "$interface" >>"$state_dir/requests.log"

printf 'BIND family=%s device=%s src=%s mark=%s\n' "${FAMILY:-$family}" "${DEVICE:-$interface}" "${SRCIP:-}" "${FWMARK:-}" >>"$state_dir/requests.log"
device="${interface#ifhost!}"; device="${device%%!*}"; device="${device#if!}"
success_marker="$state_dir/login_succeeded"
[ -z "${MOCK_CONFIG_JSON:-}" ] || success_marker="$success_marker.$device"
mock_source4="${MOCK_IPV4:-10.21.2.3}"
case "$interface" in ifhost!*) [ "$family" != ipv4 ] || mock_source4="${interface##*!}" ;; esac
scenario="${MOCK_SCENARIO:-type2_success}"
if [ "$scenario" = multi_mapped ]; then scenario=type1_success; fi
if [ "${MOCK_PUBLIC_FAILURES:-0}" = 1 ]; then
 case "$url" in http://connect.test/*|https://www.baidu.com/*|https://test6.ustc.edu.cn/*|https://dns.alidns.com/*) exit 7 ;; esac
fi
case "$url" in
 http://connect.test/*) delay="${MOCK_DELAY_CONFIGURED:-}";;
 https://www.baidu.com/*|https://test6.ustc.edu.cn/*) delay="${MOCK_DELAY_USTC:-}";;
 https://dns.alidns.com/*) delay="${MOCK_DELAY_ALIDNS:-}";;
 *)delay='';;
esac
if [ -n "$delay" ];then sleep "$delay" & wait_pid=$!;trap 'kill "$wait_pid" 2>/dev/null;exit 0' 15;wait "$wait_pid";trap - 15;fi
code=404
body='not found'

case "$url" in
 https://jfself.bjut.edu.cn/Self/*)
  fixture_user="$(printf '%s' "$data" | sed -n 's/.*account=\([^&]*\).*/\1/p')"
  [ -n "$fixture_user" ] || fixture_user="$(cat "$cookie_file" 2>/dev/null)"
  mime=text/html
  code=200
  case "$url" in
   */Self/login/eportalLogin*)
    fixture_user="$(printf '%s' "$url" | sed -n 's/.*account=\([^&]*\).*/\1/p')"
    printf '%s' "$fixture_user" >"$cookie_file"
    code=302; body=''; location='/Self/dashboard' ;;
   */Self/login/verify*)
    if [ "$scenario" = billing_rejected ]; then
     body="<form method='post' action='/Self/login/verify'><input name='checkcode' value='1234'><div id='randomDiv' class='hide'></div></form>账号或密码出现错误！"
    elif [ "$scenario" = billing_captcha ] && ! printf '%s' "$data" | grep -q 'code=AB12'; then
     body="<form method='post' action='/Self/login/verify'><input name='checkcode' value='1234'><div id='randomDiv'></div></form>"
    else
     printf '%s' "$fixture_user" >"$cookie_file"
     code=302; body=''; location='/Self/dashboard'
    fi ;;
   */Self/login/randomCode*)
    mime=image/png; body=fixture-image ;;
   */Self/login/getBrandInfo*) mime=application/json; body='{}' ;;
   */Self/service/goStop*) body="<button id='stopNow'>报停</button>";;
   */Self/service/goReopen*) body="<button id='reOpenNow' disabled>复通</button>";;
   */Self/service/package*) body="<a class='pick-card' data-package='2'>套餐：新套餐 描述：测试</a><script>post('doPackage',{csrftoken:'fixture-csrf'});</script>";;
   */Self/service/consumeProtect*) body="<input name='csrftoken' value='fixture-csrf'><script>window.user=(function(x){return x})({\"installmentFlag\":100,\"useMoney\":25});</script>";;
   */Self/setting/changePassword*) body="<input name='csrftoken' value='fixture-csrf'><script>var passwordPolicy={\"FLDMINLENGTH\":8,\"FLDREQUIREUPPER\":1,\"FLDREQUIREDIGIT\":1};</script>";;
   */Self/setting/passwordQuestion*) body="<input name='csrftoken' value='fixture-csrf'><select id='question1'><option value='1'>问题一</option><option value='2'>问题二</option><option value='3'>问题三</option></select>";;
   */Self/service/myMac*) body='<html>MAC</html>';;
   */Self/service/getMacList*) mime=application/json;body='{"rows":[["在线","aabbccddeeff","测试设备","2026-10-18","10.126.19.139"]]}' ;;
   */Self/dashboard/refreshMauthType*) body="<a data-toggle='oprateMauth'>开启</a>";;
   */Self/service/stop|*/Self/service/reOpen|*/Self/service/doPackage|*/Self/service/changeConsumeProtect|*/Self/service/bindMac|*/Self/setting/changePasswordMethod|*/Self/setting/updatePasswordQuestion|*/Self/dashboard/tooffline*)
    [ "${MOCK_ACTION_TIMEOUT:-0}" != 1 ] || exit 28
    mime=application/json;body='{"state":"success","success":true}' ;;
   */Self/dashboard/getOnlineList*)
    mime=application/json; body='{"rows":[{"sessionId":"fixture-session","ip":"10.126.19.139","ipv6":"2001:db8::1","mac":"aabbccddeeff","useTime":60,"userPassword":"do not expose"}]}'
    [ "$scenario" != billing_array ] || body='[{"sessionId":"fixture-session","ip":"10.126.19.139","userPassword":"do not expose"}]'
    [ "$scenario" != billing_empty_sessions ] || body='null'
    [ "$scenario" != billing_sessions_unavailable ] || body='{"error":"session service unavailable"}' ;;
   */Self/static/login.js*) body='/* fixture asset */' ;;
   */Self/dashboard/getLoginHistory*) mime=application/json; body='{"data":[["2026-10-11","2026-10-11","10.126.19.139","","aabbccddeeff",60,42,3,0]]}' ;;
   */Self/bill/getUserOnlineLog*)
    mime=application/json; body="$(python3 "$(dirname "$0")/record_fixture.py" "$url")" ;;
   *)
    if [ -n "$fixture_user" ]; then
     body="<script>window.user=(function(x){return x})({\"userName\":\"$fixture_user\",\"leftMoney\":42,\"leftFlow\":1024,\"useFlag\":1,\"userPassword\":\"do not expose\",\"serviceDefault\":{\"defaultName\":\"fixture package\"}});var AJAXCSRFTOKEN='fixture-ajax';</script><label>状　　态：</label><div><span>正常</span></div><dl><dt>2 <small>GB</small></dt><dd>已用流量</dd></dl>"
    else
     body="<script src='/Self/static/login.js'></script><script src='https://other.test/unsafe.js'></script><form method='post' action='/Self/login/verify'><input name='checkcode' value='1234'><div id='randomDiv' class='$( [ "$scenario" = billing_captcha ] || printf hide )'></div></form>"
    fi ;;
  esac
  if [ -n "$headers" ]; then
   printf 'HTTP/1.1 %s\r\nContent-Type: %s\r\n' "$code" "$mime" >"$headers"
   [ -z "${location:-}" ] || printf 'Location: %s\r\n' "$location" >>"$headers"
  fi
  printf '%s' "$body" >"$output"; printf '%s' "$code"; exit 0
  ;;
 */eportal/portal/self*)
  if [ "$scenario" = billing_sso ] || [ "$scenario" = billing_sso_foreign ]; then
   code=200; auth_host=jfself.bjut.edu.cn
   [ "$scenario" != billing_sso_foreign ] || auth_host=foreign.invalid
   body="dr1004({\"result\":1,\"self_auth_url\":\"https://$auth_host/Self/login/eportalLogin?account=${MOCK_SSO_USER:-25000099}&timestamp=1780981775208&sign=fixture\"})"
  else code=200; body='dr1004({"result":0})'; fi ;;
	http://connect.test/generate_204)
		if [ "$scenario" = "online" ] || [ -e "$success_marker" ]; then
			code=204; body=''
		else
			code=302; body='portal'
   [ "$scenario" != ipv6_only ] || [ "$family" != ipv6 ] || { code=204; body=''; }
   [ "$scenario" != preauth_public ] || { code=204; body=''; }
		fi
		;;
	https://www.baidu.com/robots.txt|https://test6.ustc.edu.cn/|https://dns.alidns.com/)
		if [ "$scenario" = online ] || [ "$scenario" = public_tls ] || [ -e "$success_marker" ]; then code=404; body=public; else exit 7; fi
		;;
	*/drcom/chkstatus*)
		[ -z "${MOCK_PROBE_DELAY:-}" ] || sleep "$MOCK_PROBE_DELAY"
		case "$scenario" in
			type2_*|auth_rejected|ambiguous|oversized|unknown_result) code=200; body='dr1002({"result":0,"msg":"not online"});'; [ ! -e "$success_marker" ] || body='dr1002({"result":1})'; ;;
		esac
		;;
    */drcom/logout*|*/eportal/portal/logout*)
        code=200;body='dr1004({"result":1})';rm -f "$success_marker";;
	*/drcom/login*)
		case "$scenario" in
			type2_success|type2_rotate)
				if [ "$scenario" = "type2_rotate" ] && printf '%s' "$url" | grep -q 'DDDDD=25000001'; then
					code=200; body='dr1003({"result":0,"msga":"password error"});'
					[ -z "${MOCK_FIRST_REJECTION_BODY:-}" ] || body="$MOCK_FIRST_REJECTION_BODY"
				else
					code=200; body='dr1003({"result":1,"msg":"ok"});'; : >"$success_marker"
				fi
				;;
			auth_rejected) code=200; body='dr1003({"result":0,"msga":"password error"});' ;;
			ambiguous) code=200; body='unexpected response' ;;
			unknown_result) code=200; body='dr1003({"result":2,"msg":"unknown"});' ;;
			oversized)
				code=200
				body='oversized'
				;;
		esac
		;;
	*/eportal/portal/page/loadConfig*)
		[ -z "${MOCK_PROBE_DELAY:-}" ] || sleep "$MOCK_PROBE_DELAY"
		case "$scenario" in
			type1_pinned)
				if [ "$pinned" = "0" ]; then exit 60; fi
				code=200; body='dr1001({"code":1,"data":{"portal":"eportal"}});'
				;;
		type1_success|type1_already_online|portal_online|portal_unknown|preauth_public) code=200; body='dr1001({"code":1,"data":{"portal":"eportal"}});' ;;
		esac
		;;
	*/eportal/portal/online_list*)
  case "$scenario" in
   portal_online) code=200; body="dr1002({\"result\":1,\"total\":2,\"list\":[{\"online_ip\":\"10.126.99.1\",\"user_account\":\"25000001\"},{\"online_ip\":\"${mock_source4}\",\"user_account\":\"25000009\"}]});" ;;
   type1_success|type1_pinned|type1_already_online|preauth_public) code=200; body='dr1002({"result":1,"total":0,"list":[]});'; [ ! -e "$success_marker" ] || body="dr1002({\"result\":1,\"total\":1,\"list\":[{\"online_ip\":\"${mock_source4}\"}]});" ;;
   portal_unknown) code=200; body='unexpected response' ;;
  esac
  ;;
	https://lgn.bjut.edu.cn/)
		case "$scenario" in type3_*) code=200; body='<html><input name="v6ip"><script>var Dr.COMWebLoginID_=1; var authUserField="DDDDD";</script></html>' ;; esac
		;;
	*/eportal/portal/page/loadUserInfo*)
		case "$scenario" in
			type3_success|type3_no_ipv6|type3_secondary|type3_ambiguous|type3_foreign_ipv6) code=200; body='dr1002({"code":1,"user_info_lang":{"account":"账号"}});'
				[ ! -e "$success_marker" ] || body="dr1002({\"code\":1,\"user_info\":{\"account\":\"$(cat "$state_dir/login_account.$device" 2>/dev/null)\"}});" ;;
		esac
		;;
	*/drcom/getipv6*)
		case "$scenario" in
			type3_success|type3_secondary|type3_ambiguous) code=200; body='dr1004({"result":1,"ip":"2001:da8:216:2633::10"});' ;;
			type3_foreign_ipv6) code=200; body='dr1004({"result":1,"ip":"2001:db8::10"});' ;;
			type3_no_ipv6) code=200; body='dr1004({"result":0,"ip":""});' ;;
		esac
		;;
	*/eportal/portal/login*)
		case "$scenario" in
			type3_ambiguous) exit 28 ;;
			type1_already_online) code=200; body='dr1005({"result":0,"msg":"用户已在线"});' ;;
			type1_success|type1_pinned|type3_success|type3_secondary|type3_no_ipv6|type3_foreign_ipv6)
				code=200; body='dr1005({"result":1,"msg":"ok"});'; : >"$success_marker"
                if [ -n "${MOCK_FIRST_REJECTION_BODY:-}" ] && printf '%s' "$url" | grep -q '25000001';then body="$MOCK_FIRST_REJECTION_BODY";rm -f "$success_marker";fi
                fixture_encoded="$(printf '%s' "$url" | sed -n 's/.*user_account=\([^&]*\).*/\1/p')"
                if printf '%s' "$scenario" | grep -q '^type3_'; then
                    printf '%s' "$fixture_encoded" | python3 -c 'import sys; s=sys.stdin.read(); print("".join(chr(int(s[i:i+2],16)^0x16) for i in range(0,len(s),2)).removeprefix(",0,"))' >"$state_dir/login_account.$device"
                fi
				;;
		esac
		;;
esac

if [ "$scenario" = "type3_secondary" ] && printf '%s' "$*" | grep -Eq '172[.]30[.]201[.]2($| )|2001:da8:216:30c9::2]'; then
	exit 7
fi

[ -n "$output" ] || exit 2
if [ "$scenario" = "oversized" ] && printf '%s' "$url" | grep -q '/drcom/login'; then
	awk 'BEGIN { for (i = 0; i < 140000; i++) printf "x" }' >"$output"
else
	printf '%s' "$body" >"$output"
fi
printf '%s' "$code"
exit 0
