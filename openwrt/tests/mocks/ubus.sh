#!/bin/sh

case "$*" in
	*'iwinfo info'*)
		[ "${MOCK_UBUS_IWINFO:-0}" = "1" ] || exit 1
		printf '{"ssid":"%s","bssid":"%s","mode":"Client"}\n' \
			"${MOCK_SSID:-bjut_wifi}" "${MOCK_BSSID:-44:1A:FA:12:34:56}"
		;;
	*)
		cat <<EOF
{"up":${MOCK_UP:-true},"l3_device":"${MOCK_DEVICE:-wlan0}","ipv4-address":[{"address":"${MOCK_IPV4:-10.21.2.3}"}]}
EOF
		;;
esac
