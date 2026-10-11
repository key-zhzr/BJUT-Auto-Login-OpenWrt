# BJUT-Auto-Login OpenWrt / ImmortalWrt 端

这是从桌面/Android 版认证核心迁移出的路由端实现，目标是保持低常驻占用，同时保留“先探测、后认证”、固定物理出口和结果歧义保护。

## 支持范围

| 网络 | 协议 | 默认传输 | 安全模式 |
|---|---|---|---|
| `bjut-sushe`、宿舍路由器变体及宿舍有线 | Type 1 ePortal | HTTPS `:802` | 固定网关 IP、TLS SNI、正常证书验证；仅对项目已记录的旧证书启用 SPKI 固定回退 |
| `bjut_wifi` | Type 2 Dr.COM | HTTPS | 固定 `10.21.251.3`，正常证书验证 |
| `lgn` 有线 | Type 3 加密 ePortal | HTTPS + IPv4/IPv6 | 从 `lgn6` 获取网关观测到的 IPv6，全部动态字段按原客户端 UTF-16/XOR 规则编码 |

核心包不依赖 LuCI；管理页面是独立的可选包。仓库提供 OpenWrt 24.10 IPK 和 25.12 APK 的编译工作流；其他固件使用对应 SDK 编译。

## 为什么常驻占用较低

- 空闲时只有一个由 `procd` 管理的 BusyBox `ash` 睡眠进程。
- 不安装或常驻 Node、Rust、Python、WebView、数据库或独立 HTTP 服务。
- `curl`、`jsonfilter` 与轻量编码、页面读取辅助程序 仅在检测/认证时短暂启动。
- 接口 `ifup` 事件立即触发一次检查，平时按设定间隔低频检测；失败后指数退避。
- LuCI 页面仅在管理员打开时运行，不属于后台进程。

## 源码目录

- `bjut-autologin/`：核心包，包含认证脚本、微型 UTF-8/UTF-16 编码器、UCI 默认配置、`procd` 服务和 `netifd` hotplug 脚本。
- `luci-app-bjut-autologin/`：可选 LuCI 设置与计费页面，通过受限 rpcd 方法查询和操作，不授予任意命令执行权限。
- `tests/`：离线协议网关、接口、UCI、JSONP、账号轮换和安全失败测试。

## 使用 SDK 编译

也可在 GitHub Actions 中选择平台，自动生成 IPK/APK，详见 [BUILDING.md](BUILDING.md)。

选择与路由器固件版本、Target 和 Subtarget **完全一致**的 OpenWrt/ImmortalWrt SDK，然后执行：

```sh
cp -a openwrt/bjut-autologin "$SDK/package/"
cp -a openwrt/luci-app-bjut-autologin "$SDK/package/"
cd "$SDK"
./scripts/feeds update -a
./scripts/feeds install -a
make defconfig
make package/bjut-autologin/compile V=s
make package/luci-app-bjut-autologin/compile V=s
```

生成的 IPK/APK 位于 SDK 的 `bin/packages/` 或 `bin/targets/` 下。核心包会依赖 `curl`、`ca-bundle`、`rpcd-mod-iwinfo`、`rpcd`、`ip-full`、`coreutils-sha256sum`、`jshn` 和 `jsonfilter`；`rpcd-mod-iwinfo` 同时兼容传统无线脚本和不提供独立 `iwinfo` 命令的新版 `wifi-scripts-ucode`。

安装时先装核心，再按需安装 LuCI：

```sh
opkg install bjut-autologin_*.ipk
opkg install luci-app-bjut-autologin_*.ipk
```

若使用 apk 包管理器的新版本固件，请让对应 SDK 生成 `.apk`，不要强行安装其他固件版本生成的包。

## 配置

安装后可在 LuCI 的“网络 → BJUT 自动登录”中设置，也可编辑 `/etc/config/bjut-autologin`。最小配置如下：

```uci
config service 'main'
	option enabled '1'
	option network 'wwan'
	option transport 'auto'
	option login_type 'auto'
	option compatibility 'secure'
	option interval '20'
	option strict_network '1'

config account
	option enabled '1'
	option username '你的学号'
	option password '你的密码'
	option login_type 'auto'
```

单上游旧配置可继续使用。需要多个上游时，添加命名的 `uplink` 段；存在这些段后，`main.network` 不再参与认证。每条上游分别选择 IPv4、IPv6 逻辑接口，IPv6 留空时读取 IPv4 物理设备上的可用全局地址。

```uci
config uplink 'dorm_a'
	option enabled '1'
	option network 'wan14'
	option network6 'wan16'
	option transport 'ethernet'
	option login_type 'type1'
	list accounts 'student_a'

config uplink 'dorm_b'
	option enabled '1'
	option network 'wan24'
	option network6 'wan26'
	option transport 'ethernet'
	option login_type 'type1'
	list accounts 'student_b'

config account 'student_a'
	option enabled '1'
	option username '你的学号'
	option password '你的密码'
	option login_type 'auto'
```

`student_b` 同样添加为账号段。四条上游可继续增加 `wan34/wan36`、`wan44/wan46` 的段，账号可以复用。每条物理出口只配置一次，IPv4 / IPv6 放在同一段中。

- `network` / `network6` 是 netifd 逻辑接口；`device` / `device6` 可覆盖实际 Linux 设备，通常留空。
- `source4` / `source6` 可指定该设备已取得的地址；留空自动读取，不使用其他设备的地址。
- `accounts` 指定此上游的账号范围，按账号页顺序尝试；留空使用所有已启用账号。停用只影响自动登录，手动登录、计费查询和 App 同步仍可选用。
- `login_type=auto` 按接口与门户选择协议；`172.26/16` 有线优先确认 lgn，可固定 `type1/type2/type3`。
- `expected_ssid/expected_bssid` 可限制无线网络。`legacy_http` 无线仍要求精确 BSSID；默认保持安全模式。
- 默认每 20 秒检查，单次请求超时 3 秒。LuCI 每 2 秒读取状态，保留最近一次完成的结果，同时显示正在进行的检测步骤。IPv4/IPv6 同时检测，并用多个证书校验通过的 HTTPS 目标作为补充，固定公网地址避免 DNS 单点问题。
- 宿舍 `online_list` 与 lgn 账号信息用于确认会话。已认证但公网探测失败时保留登录；网络错误、未知响应、已在线结果不会自动轮换账号。明确拒绝才尝试下一账号，各上游独立冷却。

### mwan3 与出口路由

`main.mwan3=1` 自动读取现有标记掩码，使用 mwan3 的 socket wrapper，并维护仅匹配所选源地址的专用规则。更新时保留用户策略与未应用的 LuCI 修改，不重启 mwan3；移除上游后清理本项目的规则。

`main.managed_routes=1` 为绑定设备的请求维护独立 IPv4/IPv6 出口表，匹配源地址与设备。网关来自 netifd 或该设备已有路由，支持 `defaultroute=0` 的上游；没有网关证据时提示缺少默认路由，不猜测网关。路由仅存在内存，不修改普通 LAN 转发和系统主路由。停止服务时清理项目路由，配置重载时保留健康出口。

curl 8.9 及以后同时绑定设备和源地址；旧版 curl 需安装并开启 mwan3 兼容。没有这种能力时明确报错，不回退到其他上游。

保存后执行：

```sh
chmod 600 /etc/config/bjut-autologin
/etc/init.d/bjut-autologin enable
/etc/init.d/bjut-autologin restart
```

## 状态与诊断

```sh
bjut-autologin check-config
bjut-autologin status
/etc/init.d/bjut-autologin manual
logread -e bjut-autologin
```

可用 `bjut-autologin manual dorm_a student_a` 手动提交指定账号，含已停用账号。`manual` 会立即检测并绕过离线确认次数/冷却计时，但仍不会绕过接口、校园网地址、协议探测、SSID/BSSID 与 TLS 安全检查。

运行状态只写入 `/var/run/bjut-autologin/status.json`，重启后自动清空，不写闪存日志。状态中的账号已脱敏。

## 计费与 App 协作

LuCI 的“网络 → BJUT 自动登录 → 计费系统”打开后自动查询各条上游，优先通过 lgn2jfself 免密跳转获取当前认证账号，无法使用时按上游账号分配回退。同一账号通过多条上游查询时，余额合计只统计一次。也可选择单条上游或已保存账号，查询余额、流量、账户状态和在线设备。计费请求固定到 `172.21.0.16`，保持 HTTPS 域名与证书验证；支持在页面中刷新、填写验证码。先显示已读取的概览，再加载在线设备。管理员、上游、账号和源地址隔离会话，刷新时复用当前会话，账号密码或出口变化后重新建立。

App 与路由端均升级到 0.1.6 后，在 App 的“设置 → 路由协作”填写路由器 HTTPS 地址与现有管理账号。首次遇到自签证书时，App 会读取证书并显示 SHA-256 指纹供确认；确认后只信任这个具体证书，并验证 TLS 握手签名。也可手动粘贴 PEM 证书。两端独立运行，连接管理不会替换 App 的本地网络判断。

连接后可以查看所有上游，按上游、指定账号发起登录，并勾选 App 账号同步到路由器。同步仅新增或更新勾选账号，保留其他账号、排序、协议限制和上游分配；保存失败时保留原配置。路由管理密码和会话令牌只留在 App 内存，不写入日志或设置备份。路由端的账号仍按下方 UCI 安全原则保存。

协作使用已有 uhttpd/rpcd，接口为 `bjut-autologin`、协议 `apiVersion=1`，不新建匿名服务，不提供任意文件或命令接口。路由器需启用 HTTPS 管理和 `/ubus` 接口；标准 LuCI 通常已安装 `uhttpd-mod-ubus`，仅安装本体的设备需从对应固件的软件源补齐。LuCI 管理账号需要相应 ACL 权限；若已有权限受限的管理账号，可授予 `bjut-autologin-app` 组。不要为此修改 GitHub Actions 权限。

### 路由器尚未开启 HTTPS

App 的管理连接需要 HTTPS。若 `uci -q get uhttpd.main.listen_https` 没有输出，可在路由器上启用 LAN 地址的 HTTPS 监听。例如管理地址为 `192.168.1.1`：

```sh
uci add_list uhttpd.main.listen_https='192.168.1.1:443'
uci commit uhttpd
/etc/init.d/uhttpd restart
```

保留已有的 `cert`、`key` 和 `/ubus` 配置；若未配置，请参考 [OpenWrt 的 uhttpd 默认配置](https://github.com/openwrt/openwrt/blob/master/package/network/services/uhttpd/files/uhttpd.config)，补齐 TLS 支持及 `uhttpd-mod-ubus`。重启后若仍无 HTTPS 监听，检查 `logread -e uhttpd`。此操作只监听所填 LAN 地址，不需要放行 WAN 管理。

若监听配置已保存，但连接仍被拒绝，检查实际证书与生成工具：

```sh
ls -l /etc/uhttpd.crt /etc/uhttpd.key /lib/libustream-ssl.so /usr/sbin/px5g /usr/bin/openssl
```

当 TLS 库存在、证书和私钥均缺失、`px5g` 与 `openssl` 也未安装时，uhttpd 无法自动生成证书，会跳过 HTTPS 监听。启动时的 `4+0 records` 只是读取随机字节，不表示生成成功，日志也可能为空。这与 App 的证书信任提示不同，连接尚未进入 TLS 校验。可从对应固件的软件源安装生成工具：

```sh
if command -v apk >/dev/null 2>&1; then
  apk update && apk add openssl-util
else
  opkg update && opkg install openssl-util
fi && /etc/init.d/uhttpd restart

ls -l /etc/uhttpd.crt /etc/uhttpd.key
```

此命令保留现有 uhttpd 配置，由服务自动生成缺失的证书；安装失败时先处理软件源报错。已有证书和私钥时不要删除重建，也无需替换已安装的 TLS 库。启动条件和工具选择见 [ImmortalWrt 的 uhttpd 启动脚本](https://github.com/immortalwrt/immortalwrt/blob/master/package/network/services/uhttpd/files/uhttpd.init)。

使用 `https://192.168.1.1` 重新连接，在 App 内核对并确认指纹即可。证书变化时需要重新核对，不会自动替换已信任证书。系统提示 App 的本地网络权限时应允许访问所连接路由器。

## 安全说明

- 密码因 OpenWrt UCI 的性质以明文保存在 `/etc/config/bjut-autologin`；包会把文件权限设为 `0600`。能取得路由器 root 或完整 LuCI 配置权限的用户仍可读取密码。
- 凭据 URL 通过 curl 配置标准输入传入，不出现在 `ps` 命令行；日志和状态文件不记录密码、完整用户名或完整认证响应。
- 所有校园网请求使用 `curl --interface` 固定到所选上游设备，并用 `--resolve` 固定到已知网关，避免 VPN/TUN 或污染 DNS 接管认证流量。
- `legacy_http` 会明文传输账号密码，仅在校内网关确实无法使用 HTTPS 时手动启用。无线下还必须配置精确 BSSID，但 BSSID 不是密码学身份验证，风险仍显著高于 TLS。
- Type 1 的旧证书回退采用 curl 的 `--pinnedpubkey` 固定已记录证书的 SPKI；若固件中的 curl/TLS 后端不支持该能力，会安全失败，不会自动降级 HTTP。

## 已知边界

- 离线测试可以验证请求字段、状态机和安全失败逻辑，但无法替代校内三个真实网关的现场测试；首次使用建议执行 `manual` 并检查 `status`/`logread`。
- `lgn` Type 3 从所选 IPv6 接口访问 lgn6 的 IPv6 网关；IPv6 发现未通过时，在已确认 IPv4 门户的前提下只提交 IPv4 认证；不会捏造 IPv6 地址。
- LuCI 提供余额、流量、账户状态与在线设备查询。充值、账单导出及完整校园服务继续使用 App。

## 运行测试

在普通 Linux/macOS 开发机（需要 C 编译器、Python 3、Node.js 和 OpenSSL 命令行工具）执行：

```sh
python3 -m unittest -v openwrt/tests/test_openwrt_port.py
python3 openwrt/tests/run_all.py
```

测试详情及覆盖边界见 [TESTING.md](TESTING.md)。
