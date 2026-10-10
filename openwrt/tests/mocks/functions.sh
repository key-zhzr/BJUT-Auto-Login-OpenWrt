#!/bin/sh

config_load() {
	return 0
}

config_foreach() {
 if [ -n "${MOCK_CONFIG_JSON:-}" ]; then
  local callback="$1" type="$2" section
  for section in $(python3 -c 'import json,sys; print(" ".join(k for k,v in json.load(open(sys.argv[1])).items() if v.get(".type") == sys.argv[2]))' "$MOCK_CONFIG_JSON" "$type"); do "$callback" "$section"; done
  return 0
 fi
	local callback="$1" type="$2"
	case "$type" in
		service) "$callback" main ;;
		account)
			[ "${MOCK_ACCOUNT_COUNT:-1}" -ge 1 ] && "$callback" account1
			[ "${MOCK_ACCOUNT_COUNT:-1}" -ge 2 ] && "$callback" account2
			;;
	esac
}

config_get() {
	local _mock_destination="$1" _mock_section="$2" _mock_option="$3" _mock_default="${4:-}" _mock_value
 if [ -n "${MOCK_CONFIG_JSON:-}" ]; then
  _mock_value="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2],{}).get(sys.argv[3],sys.argv[4]); print(" ".join(map(str,v)) if isinstance(v,list) else int(v) if isinstance(v,bool) else v)' "$MOCK_CONFIG_JSON" "$_mock_section" "$_mock_option" "$_mock_default")"
  eval "$_mock_destination=\$_mock_value"
  return 0
 fi
	case "$_mock_section.$_mock_option" in
		main.enabled) _mock_value="${MOCK_ENABLED:-1}" ;;
		main.network) _mock_value="${MOCK_NETWORK:-wwan}" ;;
		main.device) _mock_value="${MOCK_DEVICE_OVERRIDE:-}" ;;
		main.transport) _mock_value="${MOCK_TRANSPORT:-auto}" ;;
		main.login_type) _mock_value="${MOCK_LOGIN_TYPE:-auto}" ;;
		main.compatibility) _mock_value="${MOCK_COMPATIBILITY:-secure}" ;;
		main.interval) _mock_value="${MOCK_INTERVAL:-5}" ;;
		main.timeout) _mock_value="${MOCK_TIMEOUT:-1}" ;;
		main.offline_confirmations) _mock_value="${MOCK_OFFLINE_CONFIRMATIONS:-2}" ;;
		main.max_backoff) _mock_value="${MOCK_MAX_BACKOFF:-20}" ;;
		main.credential_cooldown) _mock_value="${MOCK_CREDENTIAL_COOLDOWN:-30}" ;;
		main.post_login_delay) _mock_value="${MOCK_POST_LOGIN_DELAY:-0}" ;;
		main.online_url) _mock_value="${MOCK_ONLINE_URL:-http://connect.test/generate_204}" ;;
		main.online_code) _mock_value="${MOCK_ONLINE_CODE:-204}" ;;
		main.strict_network) _mock_value="${MOCK_STRICT_NETWORK:-1}" ;;
		main.expected_ssid) _mock_value="${MOCK_EXPECTED_SSID:-}" ;;
		main.expected_bssid) _mock_value="${MOCK_EXPECTED_BSSID:-}" ;;
		main.log_level) _mock_value="${MOCK_LOG_LEVEL:-debug}" ;;
		account1.enabled) _mock_value="${MOCK_ACCOUNT1_ENABLED:-1}" ;;
		account1.username) _mock_value="${MOCK_ACCOUNT1_USERNAME:-25000001}" ;;
		account1.password) _mock_value="${MOCK_ACCOUNT1_PASSWORD:-first secret}" ;;
		account1.login_type) _mock_value="${MOCK_ACCOUNT1_LOGIN_TYPE:-auto}" ;;
		account2.enabled) _mock_value="${MOCK_ACCOUNT2_ENABLED:-1}" ;;
		account2.username) _mock_value="${MOCK_ACCOUNT2_USERNAME:-25000002}" ;;
		account2.password) _mock_value="${MOCK_ACCOUNT2_PASSWORD:-second secret}" ;;
		account2.login_type) _mock_value="${MOCK_ACCOUNT2_LOGIN_TYPE:-auto}" ;;
		*) _mock_value="$_mock_default" ;;
	esac
	eval "$_mock_destination=\$_mock_value"
}

config_get_bool() {
	config_get "$@"
}
