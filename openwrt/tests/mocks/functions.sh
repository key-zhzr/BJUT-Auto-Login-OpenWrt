#!/bin/sh

config_load() {
	return 0
}

config_foreach() {
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
	local destination="$1" section="$2" option="$3" default="${4:-}" value
	case "$section.$option" in
		main.enabled) value="${MOCK_ENABLED:-1}" ;;
		main.network) value="${MOCK_NETWORK:-wwan}" ;;
		main.device) value="${MOCK_DEVICE_OVERRIDE:-}" ;;
		main.transport) value="${MOCK_TRANSPORT:-auto}" ;;
		main.login_type) value="${MOCK_LOGIN_TYPE:-auto}" ;;
		main.compatibility) value="${MOCK_COMPATIBILITY:-secure}" ;;
		main.interval) value="${MOCK_INTERVAL:-5}" ;;
		main.timeout) value="${MOCK_TIMEOUT:-1}" ;;
		main.offline_confirmations) value="${MOCK_OFFLINE_CONFIRMATIONS:-2}" ;;
		main.max_backoff) value="${MOCK_MAX_BACKOFF:-20}" ;;
		main.credential_cooldown) value="${MOCK_CREDENTIAL_COOLDOWN:-30}" ;;
		main.post_login_delay) value="${MOCK_POST_LOGIN_DELAY:-0}" ;;
		main.online_url) value="${MOCK_ONLINE_URL:-http://connect.test/generate_204}" ;;
		main.online_code) value="${MOCK_ONLINE_CODE:-204}" ;;
		main.strict_network) value="${MOCK_STRICT_NETWORK:-1}" ;;
		main.expected_ssid) value="${MOCK_EXPECTED_SSID:-}" ;;
		main.expected_bssid) value="${MOCK_EXPECTED_BSSID:-}" ;;
		main.log_level) value="${MOCK_LOG_LEVEL:-debug}" ;;
		account1.enabled) value="${MOCK_ACCOUNT1_ENABLED:-1}" ;;
		account1.username) value="${MOCK_ACCOUNT1_USERNAME:-25000001}" ;;
		account1.password) value="${MOCK_ACCOUNT1_PASSWORD:-first secret}" ;;
		account1.login_type) value="${MOCK_ACCOUNT1_LOGIN_TYPE:-auto}" ;;
		account2.enabled) value="${MOCK_ACCOUNT2_ENABLED:-1}" ;;
		account2.username) value="${MOCK_ACCOUNT2_USERNAME:-25000002}" ;;
		account2.password) value="${MOCK_ACCOUNT2_PASSWORD:-second secret}" ;;
		account2.login_type) value="${MOCK_ACCOUNT2_LOGIN_TYPE:-auto}" ;;
		*) value="$default" ;;
	esac
	eval "$destination=\$value"
}

config_get_bool() {
	config_get "$@"
}
