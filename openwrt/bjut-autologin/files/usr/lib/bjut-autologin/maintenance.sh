#!/bin/sh
# SPDX-License-Identifier: MIT
MAINT_DATA="${BJUT_DATA_DIR:-/etc/bjut-autologin}/maintenance"
MAINT_REPOSITORY='https://github.com/key-zhzr/BJUT-Auto-Login-OpenWrt'

maintenance_platform() {
 local board
 board="$("$UBUS_BIN" -S call system board 2>/dev/null)"
 MAINT_TARGET="$(network_json_value "$board" '@.release.target')"
 MAINT_ARCH="$(sed -n "s/^DISTRIB_ARCH='\([^']*\)'/\1/p" "${BJUT_RELEASE_FILE:-/etc/openwrt_release}")"
 if command -v apk >/dev/null 2>&1; then
  MAINT_FORMAT=apk
  MAINT_INSTALLED="$(apk list --installed 'bjut-autologin' 2>/dev/null | awk '/^bjut-autologin-/{sub(/^bjut-autologin-/,"",$1);print $1;exit}')"
  MAINT_LUCI_INSTALLED="$(apk list --installed 'luci-app-bjut-autologin' 2>/dev/null | awk '/^luci-app-bjut-autologin-/{sub(/^luci-app-bjut-autologin-/,"",$1);print $1;exit}')"
 else
  MAINT_FORMAT=ipk
  MAINT_INSTALLED="$(opkg status bjut-autologin 2>/dev/null | sed -n 's/^Version: //p')"
  MAINT_LUCI_INSTALLED="$(opkg status luci-app-bjut-autologin 2>/dev/null | sed -n 's/^Version: //p')"
 fi
 case "$MAINT_TARGET:$MAINT_ARCH" in *[!A-Za-z0-9_./:-]*|:|*:|:*) return 1;; esac
}

maintenance_info() (
 local directory id comma='' latest
 maintenance_platform || { reply error '无法确认路由器平台'; return; }
 json_init; json_add_string version "$MAINT_INSTALLED"; json_add_string target "$MAINT_TARGET"
 json_add_string arch "$MAINT_ARCH"; json_add_string format "$MAINT_FORMAT"
 json_add_string luciVersion "${MAINT_LUCI_INSTALLED:-}"
 json_add_string lastJob "$(cat "$STATE_DIR/maintenance-last" 2>/dev/null)"
 json_add_string rollback "$(cat "$MAINT_DATA/rollback-current" 2>/dev/null)"
 printf '{"platform":'; json_dump; printf ',"backups":['
 set +f
 for directory in "$MAINT_DATA"/backup-*; do
  [ -d "$directory" ] && [ -s "$directory/config" ] || continue
  id="${directory##*/}"; json_init; json_add_string id "$id"
  json_add_string createdAt "$(cat "$directory/created" 2>/dev/null)"
  json_add_string version "$(cat "$directory/version" 2>/dev/null)"
  printf '%s' "$comma"; comma=,; json_dump
 done
 printf ']}\n'
)

maintenance_progress() (
 local state="$1" message="$2" percent="$3" file="$MAINT_JOB/result.json"
 . "$JSHN_SH"
 json_init; json_add_string state "$state"; json_add_string message "$message"; json_add_int percent "$percent"
 [ -z "${MAINT_TAG:-}" ] || json_add_string release "$MAINT_TAG"
 [ -z "${MAINT_BACKUP:-}" ] || json_add_string backup "$MAINT_BACKUP"
 json_add_string target "$MAINT_TARGET"; json_add_string arch "$MAINT_ARCH"; json_add_string format "$MAINT_FORMAT"
 json_dump >"$file.$$" && mv -f "$file.$$" "$file"
)

maintenance_backup() {
 local id directory original="${BJUT_CONFIG_DIR:-/etc/config}/bjut-autologin" old count=0
 id="backup-$(date +%s)-$("$CODEC_BIN" random16 | cut -c1-8)"; directory="$MAINT_DATA/$id"
 mkdir -p "$directory" && chmod 0700 "$MAINT_DATA" "$directory" || return 1
 cp "$original" "$directory/config" && chmod 0600 "$directory/config" || return 1
 date '+%Y-%m-%d %H:%M:%S' >"$directory/created"
 printf '%s' "$MAINT_INSTALLED" >"$directory/version"
 MAINT_BACKUP="$id"
 # Bound persistent storage; backup data never enters a public web directory.
 set +f
 for old in $(printf '%s\n' "$MAINT_DATA"/backup-* | sort -r); do
  [ -d "$old" ] || continue
  count=$((count+1)); [ "$count" -le 8 ] || rm -rf -- "$old"
 done
}

maintenance_verify_pair() {
 local directory="$1" index=0 package digest actual seen=''
 [ "$(json_file_value "$directory/manifest.json" '@.target')" = "$MAINT_TARGET" ] &&
 [ "$(json_file_value "$directory/manifest.json" '@.arch')" = "$MAINT_ARCH" ] &&
 [ "$(json_file_value "$directory/manifest.json" '@.format')" = "$MAINT_FORMAT" ] || return 1
 [ -z "$(json_file_value "$directory/manifest.json" '@.files[2]')" ] || return 1
 while [ "$index" -lt 2 ]; do
  package="$(json_file_value "$directory/manifest.json" "@.files[$index].package")"
  case "$package" in bjut-autologin|luci-app-bjut-autologin) ;; *) return 1;; esac
  case "|$seen|" in *"|$package|"*) return 1;; esac; seen="$seen|$package"
  digest="$(json_file_value "$directory/manifest.json" "@.files[$index].sha256")"
  actual="$(sha256sum "$directory/$package.$MAINT_FORMAT" 2>/dev/null | awk '{print $1}')"
  [ "${#digest}" = 64 ] && [ "$actual" = "$digest" ] || return 1
  index=$((index+1))
 done
}

maintenance_fetch() {
 local url="$1" output="$2" code
 case "$url" in
  https://api.github.com/repos/key-zhzr/BJUT-Auto-Login-OpenWrt/releases*|https://github.com/key-zhzr/BJUT-Auto-Login-OpenWrt/releases/download/*) ;;
  *) return 1;;
 esac
 # Release downloads redirect to GitHub's asset CDN; all hops require TLS.
 code="$("$CURL_BIN" --disable --silent --show-error --fail --location --max-redirs 4 --proto '=https' --proto-redir '=https' --noproxy '*' \
  --connect-timeout 3 --max-time 45 --max-filesize 16777216 --header 'Accept: application/vnd.github+json' \
  --output "$output" --write-out '%{http_code}' --url "$url" 2>/dev/null)" && [ "$code" = 200 ]
}

maintenance_manifest() {
 local tag="$1" output="$2" aggregate index=0 candidate
 case "$tag" in ''|*[!A-Za-z0-9_.-]*) return 1;; esac
 # Published releases contain one aggregate builds.json, not per-SDK assets.
 aggregate="$output.builds"
 maintenance_fetch "$MAINT_REPOSITORY/releases/download/$tag/builds.json" "$aggregate" || return 1
 while [ "$index" -lt 64 ];do
  candidate="$(json_file_value "$aggregate" "@[$index]")";[ -n "$candidate" ] || break
  printf '%s' "$candidate" >"$output.candidate"
  if [ "$(json_file_value "$output.candidate" '@.target')" = "$MAINT_TARGET" ] &&
   [ "$(json_file_value "$output.candidate" '@.arch')" = "$MAINT_ARCH" ] &&
   [ "$(json_file_value "$output.candidate" '@.format')" = "$MAINT_FORMAT" ];then
   mv -f "$output.candidate" "$output";return 0
  fi
  index=$((index+1))
 done
 return 1
}

maintenance_download_pair() {
 local manifest="$1" tag="$2" directory="$3" index=0 package name digest size actual count=0 version='' pair_version
 mkdir -p "$directory" || return 1
 [ -z "$(json_file_value "$manifest" '@.files[2]')" ] || return 1
 while [ "$index" -lt 2 ]; do
  package="$(json_file_value "$manifest" "@.files[$index].package")"
  name="$(json_file_value "$manifest" "@.files[$index].name")"
  digest="$(json_file_value "$manifest" "@.files[$index].sha256")"
  size="$(json_file_value "$manifest" "@.files[$index].size")"
  case "$package" in bjut-autologin|luci-app-bjut-autologin) ;; *) return 1;; esac
  case "$name" in *[!A-Za-z0-9_.-]*|'') return 1;; esac
  if [ "$MAINT_FORMAT" = apk ]; then
   case "$name" in *"__$package-"*.apk) ;; *) return 1;; esac
   pair_version="${name##*__$package-}"; pair_version="${pair_version%.apk}"
  else
   case "$name" in *"__${package}_"*.ipk) ;; *) return 1;; esac
   pair_version="${name##*__${package}_}"; pair_version="${pair_version%%_*}"
  fi
  case "$digest" in *[!a-f0-9]*) return 1;; esac
  [ "${#digest}" = 64 ] && valid_range "$size" 1 2097152 || return 1
  [ -n "$version" ] || version="$pair_version"
  [ "$version" = "$pair_version" ] || return 1
  [ ! -e "$directory/$package.$MAINT_FORMAT" ] || return 1
  maintenance_fetch "$MAINT_REPOSITORY/releases/download/$tag/$name" "$directory/$package.$MAINT_FORMAT" || return 1
  actual="$(sha256sum "$directory/$package.$MAINT_FORMAT" | awk '{print $1}')"
  [ "$actual" = "$digest" ] && [ "$(wc -c <"$directory/$package.$MAINT_FORMAT" | tr -d ' \011\012\015')" = "$size" ] || return 1
  index=$((index+1)); count=$((count+1))
 done
 [ "$count" = 2 ] && [ -f "$directory/bjut-autologin.$MAINT_FORMAT" ] && [ -f "$directory/luci-app-bjut-autologin.$MAINT_FORMAT" ] || return 1
 cp "$manifest" "$directory/manifest.json"
}

maintenance_is_newer() {
 local manifest="$1" index=0 package name version
 while [ "$index" -lt 2 ];do
  package="$(json_file_value "$manifest" "@.files[$index].package")"
  if [ "$package" = bjut-autologin ];then
   name="$(json_file_value "$manifest" "@.files[$index].name")"
   if [ "$MAINT_FORMAT" = apk ];then version="${name##*__bjut-autologin-}";version="${version%.apk}"
   else version="${name##*__bjut-autologin_}";version="${version%%_*}";fi
   awk -v previous="$MAINT_INSTALLED" -v next_version="$version" 'BEGIN{
    sub(/-r/,"-",previous);sub(/-r/,"-",next_version)
    if(previous!~/^[0-9]+[.][0-9]+[.][0-9]+-[0-9]+$/ || next_version!~/^[0-9]+[.][0-9]+[.][0-9]+-[0-9]+$/)exit 1
    split(previous,a,/[.-]/);split(next_version,b,/[.-]/)
    for(i=1;i<=4;i++){if(b[i]+0>a[i]+0)exit 0;if(b[i]+0<a[i]+0)exit 1}exit 1
   }';return $?
  fi
  index=$((index+1))
 done
 return 1
}

maintenance_simulate() {
 local directory="$1"
 maintenance_verify_pair "$directory" || return 1
 if [ "$MAINT_FORMAT" = apk ]; then
  apk add --simulate --no-network --allow-untrusted --upgrade "$directory/bjut-autologin.apk" "$directory/luci-app-bjut-autologin.apk" >"$MAINT_JOB/plan.txt" 2>&1 || return 1
 else
  opkg --noaction install "$directory/bjut-autologin.ipk" "$directory/luci-app-bjut-autologin.ipk" >"$MAINT_JOB/plan.txt" 2>&1 || return 1
 fi
 awk '/Removing|Purging/{exit 1} /Installing|Upgrading|Downgrading|Reinstalling/{for(i=1;i<NF;i++)if($i~/^(Installing|Upgrading|Downgrading|Reinstalling)$/ && $(i+1)!="bjut-autologin" && $(i+1)!="luci-app-bjut-autologin")exit 1}' "$MAINT_JOB/plan.txt"
}

maintenance_install() {
 local directory="$1" result=0 available needed
 maintenance_simulate "$directory" || return 1
 available="$(df -Pk "$MAINT_DATA" | awk 'NR==2{print $4}')"; needed="$(du -sk "$directory" | awk '{print $1}')"
 is_uint "$available" && is_uint "$needed" && [ "$available" -gt "$((needed+1024))" ] || { maintenance_progress error '可用存储不足，未安装更新' 100; return 1; }
 maintenance_backup || return 1
 if [ -n "${MAINT_ROLLBACK_DIR:-}" ]; then
  printf '%s' "$MAINT_BACKUP" >"$MAINT_ROLLBACK_DIR/config-id"
  cp "$MAINT_DATA/$MAINT_BACKUP/config" "$MAINT_ROLLBACK_DIR/config" || return 1
 fi
 if [ "$MAINT_FORMAT" = apk ]; then
  apk add --no-network --allow-untrusted --upgrade "$directory/bjut-autologin.apk" "$directory/luci-app-bjut-autologin.apk" >"$MAINT_JOB/install.txt" 2>&1 || result=1
 else opkg install "$directory/bjut-autologin.ipk" "$directory/luci-app-bjut-autologin.ipk" >"$MAINT_JOB/install.txt" 2>&1 || result=1; fi
 /etc/init.d/bjut-autologin restart >/dev/null 2>&1 || result=1
 return "$result"
}

maintenance_worker() {
 local ticket="$1" action prepared backup list index tag current_tag base revision directory available
 MAINT_JOB="$STATE_DIR/maintenance/$ticket"
 action="$(json_file_value "$MAINT_JOB/request.json" '@.action')"
 maintenance_platform || return 1
 mkdir -p "$MAINT_DATA"; chmod 0700 "$MAINT_DATA"
 maintenance_progress loading '正在准备路由维护' 5
 case "$action" in
  backup) maintenance_backup && maintenance_progress ready '路由配置已备份' 100; return $?;;
  restore)
   backup="$(json_file_value "$MAINT_JOB/request.json" '@.backup')"
   case "$backup" in backup-*[!A-Za-z0-9-]*|'') return 1;; backup-*) ;; *) return 1;; esac
   [ -f "$MAINT_DATA/$backup/config" ] || return 1
   directory="$MAINT_JOB/config"; mkdir "$directory" || return 1
   cp "$MAINT_DATA/$backup/config" "$directory/bjut-autologin" || return 1
   UCI_CONFIG_DIR="$directory" "$SELF_BIN" check-config >/dev/null 2>&1 || { maintenance_progress error '备份配置与当前版本不兼容，未恢复' 100; return 1; }
   maintenance_backup || return 1
   cp "$directory/bjut-autologin" "${BJUT_CONFIG_DIR:-/etc/config}/bjut-autologin.new" && chmod 0600 "${BJUT_CONFIG_DIR:-/etc/config}/bjut-autologin.new" && mv -f "${BJUT_CONFIG_DIR:-/etc/config}/bjut-autologin.new" "${BJUT_CONFIG_DIR:-/etc/config}/bjut-autologin" || return 1
   /etc/init.d/bjut-autologin restart >/dev/null 2>&1 && maintenance_progress ready '配置已恢复' 100; return $?;;
  check|prepare)
   list="$MAINT_JOB/releases.json"
   maintenance_fetch 'https://api.github.com/repos/key-zhzr/BJUT-Auto-Login-OpenWrt/releases?per_page=5' "$list" || { maintenance_progress error '无法读取更新信息，请稍后重试' 100; return 1; }
   index=0; tag=''
   while [ "$index" -lt 5 ]; do
    tag="$(json_file_value "$list" "@[$index].tag_name")"; case "$tag" in openwrt-v*) break;; esac
    tag=''; index=$((index+1))
   done
   [ -n "$tag" ] || return 1
   MAINT_TAG="$tag"; maintenance_progress loading '正在核对平台和安装包' 15
   maintenance_manifest "$tag" "$MAINT_JOB/manifest.json" || { maintenance_progress error '此平台暂未提供匹配的安装包' 100; return 1; }
   maintenance_is_newer "$MAINT_JOB/manifest.json" || { maintenance_progress ready '当前版本无需更新' 100;return 0; }
   if [ "$action" = check ]; then maintenance_progress ready '已找到匹配的更新，请准备安装包后再安装' 100; return; fi
   maintenance_progress loading '正在下载并校验两个配套安装包' 30
   maintenance_download_pair "$MAINT_JOB/manifest.json" "$tag" "$MAINT_JOB/packages" || return 1
   base="${MAINT_INSTALLED%-*}"; revision="${MAINT_INSTALLED##*-}"; revision="${revision#r}"
   is_uint "$revision" || return 1
   current_tag="openwrt-v$base-r$revision"
   maintenance_progress loading '正在准备当前版本的回退包' 60
   maintenance_manifest "$current_tag" "$MAINT_JOB/rollback-manifest.json" && maintenance_download_pair "$MAINT_JOB/rollback-manifest.json" "$current_tag" "$MAINT_JOB/rollback" || { maintenance_progress error '无法准备回退包，已停止更新准备' 100; return 1; }
   maintenance_simulate "$MAINT_JOB/packages" || { maintenance_progress error '安装检查未通过，请核对软件源和依赖' 100; return 1; }
   printf '%s' "$(date +%s)" >"$MAINT_JOB/prepared"
   maintenance_progress prepared '安装包已校验，可安装；安装前将自动备份配置' 100;;
  upgrade)
   prepared="$(json_file_value "$MAINT_JOB/request.json" '@.prepared')"; valid_ticket "$prepared" || return 1
   directory="$STATE_DIR/maintenance/$prepared"
   available="$(cat "$directory/prepared" 2>/dev/null)"; is_uint "$available" && [ "$(($(date +%s)-available))" -lt 1800 ] || return 1
   [ -z "${MAINT_LUCI_INSTALLED:-}" ] || [ "$MAINT_LUCI_INSTALLED" = "$MAINT_INSTALLED" ] || { maintenance_progress error '核心与 LuCI 版本不一致，请先安装同一版本的两个包' 100;return 1; }
   [ "$(json_file_value "$directory/manifest.json" '@.target')" = "$MAINT_TARGET" ] && [ "$(json_file_value "$directory/manifest.json" '@.arch')" = "$MAINT_ARCH" ] || return 1
   maintenance_progress loading '正在备份并安装路由端更新' 70
   backup="rollback-$(date +%s)"; mkdir "$MAINT_DATA/$backup" || return 1
   maintenance_verify_pair "$directory/rollback" || return 1
   available="$(df -Pk "$MAINT_DATA" | awk 'NR==2{print $4}')"
   is_uint "$available" && [ "$available" -gt 1024 ] || return 1
   cp "$directory/rollback/bjut-autologin.$MAINT_FORMAT" "$directory/rollback/luci-app-bjut-autologin.$MAINT_FORMAT" "$directory/rollback/manifest.json" "$MAINT_DATA/$backup/" || return 1
   MAINT_ROLLBACK_DIR="$MAINT_DATA/$backup"
   printf '%s' "$backup" >"$MAINT_DATA/rollback-current"
   maintenance_install "$directory/packages" || { maintenance_progress error '安装未完成，可使用保留的回退包恢复' 100; return 1; }
   maintenance_progress ready '安装完成，正在恢复路由协作；LuCI 请刷新页面' 100;;
  rollback)
   backup="$(cat "$MAINT_DATA/rollback-current" 2>/dev/null)"
   case "$backup" in rollback-*[!0-9]*|'') return 1;; rollback-*) ;; *) return 1;; esac
   maintenance_progress loading '正在回退到升级前的配套版本' 70
   maintenance_install "$MAINT_DATA/$backup" || return 1
   prepared="$(cat "$MAINT_DATA/$backup/config-id" 2>/dev/null)"
   if [ -f "$MAINT_DATA/$backup/config" ]; then
    cp "$MAINT_DATA/$backup/config" "${BJUT_CONFIG_DIR:-/etc/config}/bjut-autologin.new" && chmod 0600 "${BJUT_CONFIG_DIR:-/etc/config}/bjut-autologin.new" && mv -f "${BJUT_CONFIG_DIR:-/etc/config}/bjut-autologin.new" "${BJUT_CONFIG_DIR:-/etc/config}/bjut-autologin" || return 1
    /etc/init.d/bjut-autologin restart >/dev/null 2>&1 || return 1
   fi
   maintenance_progress ready '路由端与升级前配置已恢复，正在恢复连接' 100;;
  *) return 1;;
 esac
}

maintenance_start() (
 local action prepared backup ticket directory active state owner guard="$STATE_DIR/maintenance-launch.lock"
 trap - 0
 if ! mkdir "$guard" 2>/dev/null; then
  owner="$(cat "$guard/pid" 2>/dev/null)"
  if is_uint "$owner" && kill -0 "$owner" 2>/dev/null; then reply error '另一项维护正在启动，请稍候'; return; fi
  rm -rf "$guard"; mkdir "$guard" || return 1
 fi
 printf '%s' "$$" >"$guard/pid"; trap 'rm -rf "$guard"' 0
 action="$(request_value action)"; prepared="$(request_value prepared)"; backup="$(request_value backup)"
 case "$action" in check|prepare|backup|rollback) ;; upgrade) valid_ticket "$prepared" || { reply error '请先准备安装包'; return; };; restore) case "$backup" in backup-*[!A-Za-z0-9-]*|'') reply error '请选择有效的备份'; return;; backup-*) ;; *) reply error '请选择有效的备份'; return;; esac;; *) reply error '维护操作无效'; return;; esac
 active="$(cat "$STATE_DIR/maintenance-last" 2>/dev/null)"
 if valid_ticket "$active" && [ -d "$STATE_DIR/maintenance/$active/lock" ]; then reply error '另一项维护正在进行，请稍候'; return; fi
 ticket="$(random_ticket)"; valid_ticket "$ticket" || return 1
 directory="$STATE_DIR/maintenance/$ticket"; mkdir -p "$directory" || return 1
 json_init; json_add_string action "$action"; json_add_string prepared "$prepared"; json_add_string backup "$backup"; json_dump >"$directory/request.json"
 printf '%s' "$(date +%s)" >"$directory/created"
 mkdir "$directory/lock" || return 1
 printf '%s' "$ticket" >"$STATE_DIR/maintenance-last"
 /bin/sh "${BJUT_MAINTENANCE:-/usr/libexec/bjut-maintenance}" "$ticket" </dev/null >/dev/null 2>&1 &
 json_init; json_add_string state loading; json_add_string ticket "$ticket"; json_add_string message '路由维护已开始'; json_dump
)

maintenance_poll() {
 local ticket file worker created state
 ticket="$(request_value ticket)"; valid_ticket "$ticket" || { reply error '维护记录无效'; return; }
 file="$STATE_DIR/maintenance/$ticket/result.json"
 worker="$(cat "$STATE_DIR/maintenance/$ticket/worker-pid" 2>/dev/null)"; created="$(cat "$STATE_DIR/maintenance/$ticket/created" 2>/dev/null)"
 state="$(json_file_value "$file" '@.state')"
 if { [ "$state" = loading ] || [ -z "$state" ]; } && { { is_uint "$worker" && ! kill -0 "$worker" 2>/dev/null; } || { ! is_uint "$worker" && is_uint "$created" && [ "$(($(date +%s)-created))" -gt 10 ]; } || { is_uint "$created" && [ "$(($(date +%s)-created))" -gt 900 ]; }; }; then
  rm -rf "$STATE_DIR/maintenance/$ticket/lock"
  reply error '维护任务已中断，请先读取路由器当前版本再重试'; return
 fi
 [ -s "$file" ] && cat "$file" || reply loading '正在准备路由维护'
}
