#!/bin/sh
# SPDX-License-Identifier: MIT
# Called only after fresh, source-bound portal and network-identity checks.
logout_protocol() {
 local protocol="$1" url base referer resolve="" host="" profile=strict key value section user password="" accepted=0 account family=ipv4
 case "$protocol" in
  type1)
   account="${OBSERVED_ACCOUNT:-$RUNTIME_ACCOUNT}"; account="${account%@campus}"
   for section in $ACCOUNT_SECTIONS; do
    config_get user "$section" username ""
    if [ "${user%@campus}" = "$account" ]; then config_get password "$section" password ""; break; fi
   done
   [ -n "$account" ] && [ -n "$password" ] || { log_message warning '当前账号缺少已保存密码，可从计费系统下线'; return 1; }
   if [ "$CFG_COMPATIBILITY" = legacy_http ]; then base="http://$DORM_GATEWAY:801"; referer="http://$DORM_GATEWAY/"; profile=http
   else base="https://$TYPE1_TLS_HOST:802"; referer="https://$DORM_GATEWAY:802/"; resolve="$TYPE1_TLS_HOST:802:$DORM_GATEWAY"; host="$DORM_GATEWAY:802"; profile="$TYPE1_TLS_PROFILE"; fi
   url="$base/eportal/portal/logout?callback=dr1004&login_method=1&user_account=$(urlencode "$account@campus")&user_password=$(urlencode "$password")&ac_logout=0&register_mode=0&wlan_user_ip=$(urlencode "$LOCAL_IPV4")&wlan_user_ipv6=&wlan_vlan_id=0&wlan_user_mac=000000000000&wlan_ac_ip=&wlan_ac_name=&jsVersion=4.2.1&v=$(request_id)&lang=zh"
   password="";;
  type2)
   if [ "$CFG_COMPATIBILITY" = legacy_http ]; then base="http://$WIFI_GATEWAY"; referer="$base/"; profile=http
   else base=https://wlgn.bjut.edu.cn; referer="$base/"; resolve="wlgn.bjut.edu.cn:443:$WIFI_GATEWAY"; fi
   url="$base/drcom/logout?callback=dr1004&jsVersion=4.1&v=$(request_id)&lang=zh";;
  type3)
   url='https://lgn.bjut.edu.cn:802/eportal/portal/logout?'
   for key in callback login_method user_account user_password ac_logout register_mode wlan_user_ip wlan_user_ipv6 wlan_vlan_id wlan_user_mac wlan_ac_ip wlan_ac_name jsVersion program_index page_index; do
    case "$key" in callback) value=dr1008;; login_method|register_mode) value=1;; user_account) value=drcom;; user_password) value=123;; ac_logout|wlan_vlan_id) value=0;; wlan_user_ip) value="$LOCAL_IPV4";; wlan_user_ipv6) value="$OBSERVED_IPV6";; wlan_user_mac) value=000000000000;; jsVersion) value=4.2.2;; program_index) value=o4OBee1755497815;; page_index) value=cHAmjX1755497856;; *) value="";; esac
    url="$url$key=$(eportal_encrypt "$value")&"
   done
   url="${url}encrypt=1&v=$(request_id)&lang=zh"; referer=https://lgn.bjut.edu.cn/; resolve="lgn.bjut.edu.cn:802:${LGN_SELECTED_GATEWAY:-$LGN_GATEWAY_PRIMARY}";family="${LGN_SELECTED_FAMILY:-ipv4}";;
  *) return 1;;
 esac
 log_message info "正在注销 $(protocol_name "$protocol") 当前接口会话"
 if http_request "$url" "$referer" "$resolve" "$host" "$profile" "$family" && http_success && load_jsonp && [ "$(jsonp_value '@.result')" = 1 ]; then accepted=1; fi
 read_portal_session "$protocol"
 [ "$SESSION_STATE" != online ] && { [ "$SESSION_STATE" = offline ] || [ "$accepted" = 1 ]; }
}
