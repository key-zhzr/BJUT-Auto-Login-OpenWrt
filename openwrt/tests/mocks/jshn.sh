#!/bin/sh

json_init() {
	_MOCK_JSON=""
}

_json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

_json_append() {
	_MOCK_JSON="${_MOCK_JSON}${_MOCK_JSON:+,}$1"
}

json_add_string() {
	local key value
	key="$(_json_escape "$1")"
	value="$(_json_escape "$2")"
	_json_append "\"$key\":\"$value\""
}

json_add_int() {
	local key="$1" value="$2"
	_json_append "\"$key\":$value"
}

json_dump() {
	printf '{%s}\n' "$_MOCK_JSON"
}
