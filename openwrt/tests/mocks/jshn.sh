#!/bin/sh

json_init() {
	_MOCK_JSON=""
	_MOCK_DEPTH=0; _MOCK_KIND=object
}

json_load() {
    _MOCK_DEPTH=0;_MOCK_KIND=object
	_MOCK_JSON="$(printf '%s' "$1" | python3 -c 'import json,sys; s=json.dumps(json.load(sys.stdin),ensure_ascii=False,separators=(",",":")); print(s[1:-1])')"
}

json_get_keys() {
	local target="$1" _mock_keys
	_mock_keys="$(printf '{%s}' "$_MOCK_JSON" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).keys()))')"
	# The assignment expression is fixed; JSON values are never evaluated as code.
	eval "$target=\$_mock_keys"
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
	if [ "${_MOCK_KIND:-object}" = array ]; then _json_append "\"$value\""; else _json_append "\"$key\":\"$value\""; fi
}

json_add_array() {
	_MOCK_DEPTH=$((_MOCK_DEPTH+1))
	eval "_MOCK_PARENT_${_MOCK_DEPTH}=\$_MOCK_JSON"
	eval "_MOCK_KIND_${_MOCK_DEPTH}=\$_MOCK_KIND"
	local key="$(_json_escape "$1")"
	eval "_MOCK_KEY_${_MOCK_DEPTH}=\$key"
	_MOCK_JSON=""; _MOCK_KIND=array
}

json_close_array() {
	local child="[$_MOCK_JSON]" key
	eval "_MOCK_JSON=\$_MOCK_PARENT_${_MOCK_DEPTH}"
	eval "_MOCK_KIND=\$_MOCK_KIND_${_MOCK_DEPTH}"
	eval "key=\$_MOCK_KEY_${_MOCK_DEPTH}"
	_MOCK_DEPTH=$((_MOCK_DEPTH-1))
	if [ "$_MOCK_KIND" = array ]; then _json_append "$child"; else _json_append "\"$key\":$child"; fi
}

json_add_int() {
	local key="$1" value="$2"
	_json_append "\"$key\":$value"
}

json_dump() {
	printf '{%s}\n' "$_MOCK_JSON"
}

json_get_type() {
 local _target="$1" _key="$2" _value
 _value="$(printf '{%s}' "$_MOCK_JSON" | python3 -c 'import json,sys;v=json.load(sys.stdin).get(sys.argv[1]);print("string" if isinstance(v,str) else "object" if isinstance(v,dict) else "array" if isinstance(v,list) else "boolean" if isinstance(v,bool) else "int" if isinstance(v,int) else "null")' "$_key")"
 eval "$_target=\$_value"
}
json_get_var() {
 local _target="$1" _key="$2" _value
 _value="$(printf '{%s}' "$_MOCK_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get(sys.argv[1],""))' "$_key")"
 eval "$_target=\$_value"
}

json_add_object() {
 _MOCK_DEPTH=$((_MOCK_DEPTH+1))
 eval "_MOCK_PARENT_${_MOCK_DEPTH}=\$_MOCK_JSON"
 eval "_MOCK_KIND_${_MOCK_DEPTH}=\$_MOCK_KIND"
 local key="$(_json_escape "$1")"
 eval "_MOCK_KEY_${_MOCK_DEPTH}=\$key"
 _MOCK_JSON="";_MOCK_KIND=object
}
json_close_object() {
 local child="{$_MOCK_JSON}" key
 eval "_MOCK_JSON=\$_MOCK_PARENT_${_MOCK_DEPTH}"
 eval "_MOCK_KIND=\$_MOCK_KIND_${_MOCK_DEPTH}"
 eval "key=\$_MOCK_KEY_${_MOCK_DEPTH}"
 _MOCK_DEPTH=$((_MOCK_DEPTH-1))
 if [ "$_MOCK_KIND" = array ];then _json_append "$child";else _json_append "\"$key\":$child";fi
}

json_add_boolean() {
 local key="$1" value=false
 [ "$2" != 1 ] && [ "$2" != true ] || value=true
 _json_append "\"$key\":$value"
}
