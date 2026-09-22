#!/bin/sh

state_dir="${MOCK_STATE_DIR:?}"
mkdir -p "$state_dir"
config="$(cat)"
url="$(printf '%s\n' "$config" | sed -n 's/^url = "\(.*\)"$/\1/p')"
output=""
pinned=0
interface=""
previous=""
for argument in "$@"; do
	case "$previous" in
		--output) output="$argument" ;;
		--interface) interface="$argument" ;;
	esac
	[ "$argument" = "--pinnedpubkey" ] && pinned=1
	previous="$argument"
done
printf 'ARGS %s\n' "$*" >>"$state_dir/requests.log"
printf 'URL %s\n' "$url" >>"$state_dir/requests.log"
printf 'IFACE %s\n' "$interface" >>"$state_dir/requests.log"

scenario="${MOCK_SCENARIO:-type2_success}"
code=404
body='not found'

case "$url" in
	http://connect.test/generate_204)
		if [ "$scenario" = "online" ] || [ -e "$state_dir/login_succeeded" ]; then
			code=204; body=''
		else
			code=302; body='portal'
		fi
		;;
	*/drcom/chkstatus*)
		[ -z "${MOCK_PROBE_DELAY:-}" ] || sleep "$MOCK_PROBE_DELAY"
		case "$scenario" in
			type2_*|auth_rejected|ambiguous|oversized|unknown_result) code=200; body='dr1002({"result":0,"msg":"not online"});' ;;
		esac
		;;
	*/drcom/login*)
		case "$scenario" in
			type2_success|type2_rotate)
				if [ "$scenario" = "type2_rotate" ] && printf '%s' "$url" | grep -q 'DDDDD=25000001'; then
					code=200; body='dr1003({"result":0,"msga":"password error"});'
				else
					code=200; body='dr1003({"result":1,"msg":"ok"});'; : >"$state_dir/login_succeeded"
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
		case "$scenario" in
			type1_pinned)
				if [ "$pinned" = "0" ]; then exit 60; fi
				code=200; body='dr1001({"code":1,"data":{"portal":"eportal"}});'
				;;
		type1_success) code=200; body='dr1001({"code":1,"data":{"portal":"eportal"}});' ;;
		esac
		;;
	*/eportal/portal/page/loadUserInfo*)
		case "$scenario" in
			type3_success|type3_no_ipv6|type3_secondary|type3_ambiguous|type3_foreign_ipv6) code=200; body='dr1002({"code":1,"user_info":{"account":"fixture"}});' ;;
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
			type1_success|type1_pinned|type3_success|type3_secondary|type3_no_ipv6|type3_foreign_ipv6)
				code=200; body='dr1005({"result":1,"msg":"ok"});'; : >"$state_dir/login_succeeded"
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
