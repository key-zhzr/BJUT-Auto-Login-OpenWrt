#!/bin/sh
case "$2" in route|rule)
 [ -n "${MOCK_ROUTE_TRACE:-}" ] || exit 1
 exec python3 "$(dirname "$0")/ip_routes.py" "$@"
 ;; esac
if [ -n "${MOCK_NETWORK_JSON:-}" ]; then
 python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); family=sys.argv[2]; dev=sys.argv[7]; key="ipv6-address" if family == "-6" else "ipv4-address"; [print("2: %s %s %s/64 scope global"%(dev,"inet6" if family=="-6" else "inet",x["address"])) for v in d.values() if v.get("l3_device")==dev for x in v.get(key,[])]' "$MOCK_NETWORK_JSON" "$@"
 exit 0
fi
case "$*" in
	'-6 -o addr show dev '*)
		case "${MOCK_SCENARIO:-}" in type3_*) address="${MOCK_IPV6:-2001:da8:216:2633::10}" ;; *) address="${MOCK_IPV6:-}" ;; esac
		[ -z "$address" ] || printf '2: %s inet6 %s/64 scope global\n' "${MOCK_DEVICE6:-eth0}" "$address"
		;;
	'-4 -o addr show dev '*) printf '2: %s inet %s/24 scope global\n' "${MOCK_DEVICE:-wlan0}" "${MOCK_IPV4:-10.21.2.3}" ;;
	*) exit 1 ;;
esac
