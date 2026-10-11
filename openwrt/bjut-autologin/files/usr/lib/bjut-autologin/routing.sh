#!/bin/sh
# SPDX-License-Identifier: MIT
# Tables/rules exist only in RAM and match source + SO_BINDTODEVICE. Ordinary
# LAN forwarding and unbound router traffic keep their existing route policies.

route_gateway() {
	local family="$1" status="$2" device="$3" index=0 target mask hop routes
	while [ "$index" -lt 64 ]; do
		target="$(network_json_value "$status" "@.route[$index].target")"
		[ -n "$target" ] || break
		mask="$(network_json_value "$status" "@.route[$index].mask")"
		if [ "$mask" = 0 ]; then
			case "$family:$target" in 4:0.0.0.0|6:::)
				hop="$(network_json_value "$status" "@.route[$index].nexthop")"
				case "$hop" in ''|0.0.0.0|::) printf __direct ;; *) printf '%s' "$hop" ;; esac
				return
				;;
			esac
		fi
		index=$((index + 1))
	done
	# netifd may omit a disabled main-table default while mwan3 retains it in
	# its interface table. Read only defaults associated with the chosen device.
	"$IP_BIN" "-$family" route show table all dev "$device" 2>/dev/null |
		awk '$1 == "default" {owned=0; for(i=1;i<NF;i++) if($i=="proto" && $(i+1)=="186") owned=1; if(owned) next;
		 for(i=1;i<NF;i++) if($i == "via") {print $(i+1); exit}; print "__direct"; exit}'
}

remove_owned_route() {
	local file="$1" family table source device gateway owner connected_hash
	read -r family table source device gateway owner connected_hash <"$file" || return 0
	valid_range "$table" 40000 44999 && valid_device_name "$device" || return 1
	case "$family" in 4|6) ;; *) return 1 ;; esac
	"$IP_BIN" "-$family" rule del pref 900 from "$source" oif "$device" lookup "$table" protocol 186 2>/dev/null || true
	"$IP_BIN" "-$family" route flush table "$table" proto 186 2>/dev/null || true
	rm -f -- "$file"
}

ensure_family_route() {
	local family="$1" device="$2" address="$3" status="$4" source gateway key table candidate file current desired route_state target old_family old_source old_device old_gateway old_owner old_hash connected connected_hash prefix prefix_address prefix_mask
	ROUTE_RESULT=not_configured
	file="$STATE_DIR/routes-$UPLINK_ID-$family"
	if [ -z "$address" ]; then
		[ ! -f "$file" ] || remove_owned_route "$file"
		return 0
	fi
	ROUTE_RESULT=kernel
	if [ "$CFG_MANAGED_ROUTES" != 1 ]; then [ ! -f "$file" ] || remove_owned_route "$file"; return 0; fi
	gateway="$(route_gateway "$family" "$status" "$device")"
	if [ -z "$gateway" ]; then
		# Without evidence of a gateway, never invent an address or restart the
		# physical interface. Surface the missing default independently of auth.
		[ ! -f "$file" ] || remove_owned_route "$file"
		case "$family" in 4) target=223.5.5.5 ;; 6) target=2400:3200::1 ;; esac
		"$IP_BIN" "-$family" route get "$target" from "$address" oif "$device" >/dev/null 2>&1 || ROUTE_RESULT=missing_default
		return 0
	fi
	case "$family:$gateway" in
		4:__direct) source="$address/32" ;;
		6:__direct) source="$address/128" ;;
		4:*) printf '%s' "$gateway" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255) exit 1}' || return 1; source="$address/32" ;;
		6:*) printf '%s' "$gateway" | "$CODEC_BIN" validate-ipv6 >/dev/null || return 1; source="$address/128" ;;
	esac
	connected="$("$IP_BIN" "-$family" route show table all dev "$device" scope link 2>/dev/null |
		awk '{owned=0; for(i=1;i<NF;i++) if($i=="proto" && $(i+1)=="186") owned=1; if(!owned) print $1}' | sort -u)"
	connected_hash="$(printf '%s' "$connected" | "$CODEC_BIN" id32)" || return 1
	key="$(printf '%s:%s' "$UPLINK_ID" "$family" | "$CODEC_BIN" id32)" || return 1
	is_uint "$connected_hash" && is_uint "$key" || return 1
	table="$(printf '%s' "$key" | awk '{printf "%d",40000 + $1 % 5000}')"
	if [ -f "$file" ]; then
		read -r old_family table old_source old_device old_gateway old_owner old_hash <"$file"
		if ! valid_range "$table" 40000 44999; then
			# A previous failed identifier must not poison all future checks.
			rm -f -- "$file"
			ensure_family_route "$family" "$device" "$address" "$status"
			return $?
		fi
	else
		candidate=0
		while [ "$candidate" -lt 5000 ]; do
			if [ -z "$("$IP_BIN" "-$family" route show table "$table" 2>/dev/null)" ] && ! "$IP_BIN" "-$family" rule show 2>/dev/null | grep -Eq "lookup $table($| )"; then break; fi
			table=$((40000 + (table - 40000 + 1) % 5000)); candidate=$((candidate + 1))
		done
		[ "$candidate" -lt 5000 ] || return 1
	fi
	desired="$family $table $source $device $gateway $UPLINK_ID $connected_hash"
	current="$(cat "$file" 2>/dev/null)"
	if [ "$current" = "$desired" ] && "$IP_BIN" "-$family" rule show 2>/dev/null |
		awk -v host="$address" -v source="$source" -v device="$device" -v table="$table" '
		{f="";o="";t="";p=""; for(i=1;i<NF;i++) {if($i=="from") f=$(i+1); if($i=="oif") o=$(i+1); if($i=="lookup") t=$(i+1); if($i=="protocol" || $i=="proto") p=$(i+1)}
		 if((f==host || f==source) && o==device && t==table && p=="186") found=1} END{exit !found}'; then
		ROUTE_RESULT=managed; return 0
	fi
	[ ! -f "$file" ] || remove_owned_route "$file"
	# Specific gateway/address routes make neighbor resolution possible even
	# when defaultroute=0 or mwan3 marked the WAN temporarily unavailable.
	printf '%s\n' "$desired" >"$file"
	# Preserve on-link access to local authentication gateways, not only the
	# default gateway. No route from another device is copied.
	printf '%s\n' "$connected" | while IFS= read -r route_line; do
		prefix="${route_line%% *}"; [ -n "$prefix" ] || continue
		prefix_address="${prefix%/*}"; prefix_mask="${prefix##*/}"
		if [ "$family" = 6 ]; then
			[ "$prefix_address" != "$prefix" ] || prefix_mask=128
			valid_range "$prefix_mask" 1 128 || continue
			printf '%s' "$prefix_address" | "$CODEC_BIN" validate-ipv6 >/dev/null || continue
		else
			[ "$prefix_address" != "$prefix" ] || prefix_mask=32
			valid_range "$prefix_mask" 1 32 || continue
			printf '%s' "$prefix_address" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255) exit 1}' || continue
		fi
		"$IP_BIN" "-$family" route replace "$prefix" dev "$device" scope link table "$table" proto 186 || exit 1
	done || { remove_owned_route "$file"; return 1; }
	if [ "$gateway" = __direct ]; then
		"$IP_BIN" "-$family" route replace default dev "$device" src "$address" table "$table" proto 186 || { remove_owned_route "$file"; return 1; }
	else
		"$IP_BIN" "-$family" route replace "$gateway" dev "$device" scope link table "$table" proto 186 &&
		"$IP_BIN" "-$family" route replace default via "$gateway" dev "$device" src "$address" table "$table" proto 186 || { remove_owned_route "$file"; return 1; }
	fi
	"$IP_BIN" "-$family" rule add pref 900 from "$source" oif "$device" lookup "$table" protocol 186 || { remove_owned_route "$file"; return 1; }

	ROUTE_RESULT=managed
}

ensure_uplink_routes() {
	local owner attempts=0
	if ! mkdir "$STATE_DIR/route-lock" 2>/dev/null; then
		owner="$(cat "$STATE_DIR/route-lock/pid" 2>/dev/null)"
		if is_uint "$owner" && kill -0 "$owner" 2>/dev/null; then
			while [ -d "$STATE_DIR/route-lock" ] && [ "$attempts" -lt 5 ]; do sleep 1; attempts=$((attempts + 1)); done
			[ ! -d "$STATE_DIR/route-lock" ] || { ROUTE4=busy; ROUTE6=busy; return 1; }
		else rm -rf "$STATE_DIR/route-lock"; fi
		mkdir "$STATE_DIR/route-lock" 2>/dev/null || return 1
	fi
	printf '%s' "$$" >"$STATE_DIR/route-lock/pid"
	ensure_family_route 4 "$DEVICE" "$LOCAL_IPV4" "$NETWORK_JSON4" || ROUTE_RESULT=failed
	ROUTE4="$ROUTE_RESULT"
	ensure_family_route 6 "$DEVICE6" "$LOCAL_IPV6" "$NETWORK_JSON6" || ROUTE_RESULT=failed
	ROUTE6="$ROUTE_RESULT"
	rm -rf -- "$STATE_DIR/route-lock"
}

prune_uplink_routes() (
	set +f
	local file family table source device gateway owner connected_hash
	for file in "$STATE_DIR"/routes-*-*; do
		[ -f "$file" ] || continue
		read -r family table source device gateway owner connected_hash <"$file" || continue
		if ! valid_range "$table" 40000 44999; then rm -f -- "$file"; continue; fi
		if [ "$CFG_MANAGED_ROUTES" = 1 ]; then case " $UPLINK_SECTIONS " in *" $owner "*) continue ;; esac; fi
		remove_owned_route "$file"
	done
)
