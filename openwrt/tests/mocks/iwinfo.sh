#!/bin/sh

[ "${MOCK_TRANSPORT_ACTUAL:-wifi}" = "wifi" ] || exit 1
cat <<EOF
${1}     ESSID: "${MOCK_SSID:-bjut_wifi}"
          Access Point: ${MOCK_BSSID:-44:1A:FA:12:34:56}
EOF
