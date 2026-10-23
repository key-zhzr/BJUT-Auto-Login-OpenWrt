# BJUT-Auto-Login OpenWrt / ImmortalWrt 端

这是从桌面/Android 版认证核心迁移出的路由端实现，目标是保持低常驻占用，同时保留“先探测、后认证”、固定物理出口和结果歧义保护。

## 支持范围

| 网络 | 协议 | 默认传输 | 安全模式 |
|---|---|---|---|
| `bjut-sushe`、宿舍路由器变体及宿舍有线 | bjut-sushe ePortal | HTTPS `:802` | 固定网关 IP、TLS SNI、正常证书验证；仅对项目已记录的旧证书启用 SPKI 固定回退 |
| `bjut_wifi` | bjut_wifi Dr.COM | HTTPS | 固定 `10.21.251.3`，正常证书验证 |
| `lgn` 有线 | lgn 加密 ePortal | HTTPS + IPv4/IPv6 | 从 `lgn6` 获取网关观测到的 IPv6，全部动态字段按原客户端 UTF-16/XOR 规则编码 |

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

安装后可在 LuCI 的“网络 → BJUT 自动登录”中设置。账号在账号管理中编辑；设置页按上游分别选择 IPv4 / IPv6 接口。也可编辑 `/etc/config/bjut-autologin`：

```uci
config service 'main'
	option enabled '1'
	option compatibility 'secure'
	option interval '20'
	option timeout '3'
	option strict_network '1'
	option log_level 'info'
	option log_target 'system'

config account 'student_a'
	option enabled '1'
	option username '你的学号'
	option password '你的密码'
	option login_type 'auto'

config uplink 'dorm_a'
	option enabled '1'
	option network 'wan14'
	option network6 'wan16'
	option transport 'ethernet'
	option login_type 'bjut-sushe'
	list accounts 'student_a'
```

添加第二条上游时，增加 `uplink 'dorm_b'`，填写对应的 `wan24/wan26` 和账号范围。账号可以复用，每条物理出口只配置一次，IPv4 / IPv6 放在同一段中。

- `network` / `network6` 是 netifd 逻辑接口；IPv6 留空时读取 IPv4 物理设备上的可用全局地址。`device` / `device6` 可覆盖 Linux 设备，通常留空。
- `source4` / `source6` 可指定该设备已取得的地址；留空自动读取，不使用其他设备的地址。
- `accounts` 按保存顺序指定此上游的账号；在 LuCI 或 App 的接口编辑中勾选账号，用箭头调整独立顺序。留空时跟随账号管理的顺序。停用只影响自动登录，手动登录、计费和 App 同步仍可选用。
- 流量耗尽、停机等明确拒绝会立即尝试下一个账号，并按“账号拒绝后等待”跳过暂不可用的账号。修改密码或手动指定账号可重新尝试；验证码、系统繁忙、超时和无法解析的响应不会触发连续换号。
- `login_type=auto` 自动确认门户，也可指定 `bjut-sushe`、`bjut_wifi` 或 `lgn`。`172.26/16` 有线优先确认 lgn。
- `expected_ssid/expected_bssid` 可限制无线网络。`legacy_http` 无线仍要求精确 BSSID；默认保持安全模式。
- 默认每 20 秒检测，单次请求超时 3 秒。IPv4 / IPv6 和同类备用目标并行探测，首个可靠响应通过便结束等待。LuCI 通常每 2 秒刷新，检测时每秒刷新；操作账号下拉框不暂停更新，请求失败后自动重试。
- 认证会话和外网分别判断。已认证但探测失败时保留登录，未知响应或“账号已在线”不会轮换账号，明确拒绝才尝试下一账号。

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

控制台的每个端口提供登录、切换账号和注销。切换前需选择账号；注销后暂停该上游的自动认证，手动登录恢复。命令行也可使用 `bjut-autologin logout dorm_a`、`bjut-autologin switch dorm_a student_a`。

状态保存在 `/var/run/bjut-autologin/`，重启后清空，账号完整显示。信息级记录检测开始、会话判断、登录与最终状态；调试和详细级显示更多探测步骤，不记录密码和会话令牌。

### 日志设置

默认写入系统日志。设置页也可选择文件日志，配置自定义目录和单文件大小（64–4096 KiB，默认 256 KiB），达到大小后轮换为 `.1`。默认目录 `/tmp/bjut-autologin-log` 位于内存，重启清空；需要持久保存时选择挂载的存储目录。

勾选“通过网页查看日志”后会创建 `/www/bjut-autologin.log` 软链接，可通过路由器网页地址读取日志；关闭后移除本项目创建的链接。运行日志页和 App 会读取当前选择的日志来源。

### PushPlus 消息推送

在 LuCI 设置页或 App 的路由器设置中启用“PushPlus 消息推送”，填写用户令牌或消息令牌，保存后可点击“发送测试消息”。群组编码可选，留空时只发送给自己。默认关闭推送；登录与恢复提醒、异常提醒可分别开关。

各条上游独立提醒：完成联网复核后通知登录成功或恢复联网，已在线时的普通检测不重复通知。一般异常默认持续 60 秒才提醒；账号被拒绝、缺少适用账号、网络身份校验失败等明确错误立即提醒。同类异常默认每小时最多重复一次，手动注销不会触发掉线提醒。消息包含上游、认证方式、账号及双栈状态，不含密码或令牌。

推送在后台通过系统路由访问 [PushPlus 官方接口](https://www.pushplus.plus/doc/guide/api.html)，不会等待故障上游恢复或拖慢认证。请求失败后，在后续检测中每分钟最多重试一次；仅保留各上游最新的待发消息，恢复后不再补发过时的掉线提醒。日志中的“已受理消息”表示 PushPlus 接口接收成功，最终送达由 PushPlus 完成。等待重试的消息位于内存，路由器重启后清空。App 不回传已保存的令牌，编辑时留空表示保留；关闭推送不会删除令牌。

## 计费与 App 协作

LuCI 的“网络 → BJUT 自动登录 → 计费系统”打开后自动查询各条上游，优先通过 lgn2jfself 免密跳转获取当前认证账号，无法使用时按上游账号分配回退。同一账号通过多条上游查询时，余额、总流量和剩余流量合计只统计一次。也可选择单条上游或已保存账号，查询余额、流量、账户状态、七类用量与账单记录、在线设备和近期上网记录。计费请求固定到 `172.21.0.16`，保持 HTTPS 域名与证书验证；支持在页面中刷新、填写验证码。先显示已读取的概览，再按需要读取其他模块。账户服务提供报停/复通、套餐预约与取消、消费保护；设备与安全提供会话下线、MAC 绑定/解绑、无感认证、计费密码和密码保护。每次操作都核对当前账号，响应不明确时不会自动重复提交。用量与账单自动拆分较长日期范围，支持分页与本页 CSV 导出；充值继续使用 App 的当前设备功能。管理员、上游、账号和源地址隔离会话，刷新时复用当前会话，账号密码或出口变化后重新建立。

App 自动查找当前局域网网关及已连接的路由地址，通过公开的产品标识识别 BJUT 路由端；发现过程不发送账号密码。发现后从控制台连接，未找到时使用“设置 → 路由协作 → 手动连接”。首次遇到自签证书时，App 会显示 SHA-256 指纹供确认；确认后只信任该证书，也可手动粘贴 PEM。

连接后，控制台以端口卡片展示各上游的物理连接、IPv4/IPv6、认证账号、累计收发及当前速率；账号管理同时显示本机与路由账号，停用仅影响自动登录。计费中心默认查询路由器各上游并合并重复账号，仍可切换到当前设备使用完整计费服务。网络诊断附加路由上游结果，运行日志显示路由日志，设置页可编辑路由器服务和上游，账号管理可添加、编辑、删除和排序路由账号，所有协作操作都在 App 内完成。两端的网络判断、自动登录与凭据存储仍独立，断开协作后 App 继续正常使用。

LuCI 拆分为控制台、账号管理、计费系统、网络诊断、运行日志与设置；前五页采用 App 风格卡片，设置页保留 LuCI 表单。账号全部在账号管理中编辑，编号完整显示。建议使用包含上述功能的 `0.1.6-r12` 或后续安装包，旧包仍可进行基本状态查看和账号同步。

默认使用 HTTPS。已有可信局域网的 HTTP 管理服务时，可在连接弹窗勾选“允许局域网 HTTP”并填写私有 IP 地址，例如 `http://192.168.1.1`。此连接中的管理密码和账号同步内容会明文传输；不会自动降级 HTTPS，也不允许公网 HTTP 或通过重定向传递凭据。

连接后可以查看所有上游，按上游、指定账号发起登录，并勾选 App 账号同步到路由器。同步仅新增或更新勾选账号，保留其他账号、排序、协议限制和上游分配；保存失败时保留原配置。未勾选“记住路由密码”时仅在本次运行中使用；勾选后将密码与当前 Wi-Fi 名称、BSSID 或有线网关、路由器标识一同保存，仅在匹配网络中自动重连。每次发送密码或管理令牌前均确认产品和设备标识；升级前保存的资料需要手动连接一次以绑定网络。手动“停止协作”会暂停自动重连，可在设置中移除保存的密码。密码和令牌不写入日志或设置备份。路由端的账号仍按下方 UCI 安全原则保存。

协作使用已有 uhttpd/rpcd，接口为 `bjut-autologin`、协议 `apiVersion=1`，不新建匿名控制服务，不提供任意文件或命令接口。`.well-known/bjut-autologin.json` 只公布产品名、版本和接口路径。管理请求需登录 `/ubus`；标准 LuCI 通常已安装 `uhttpd-mod-ubus`，仅安装本体的设备需从对应固件的软件源补齐。LuCI 管理账号需要相应 ACL 权限；已有权限受限的管理账号可按需授予 `bjut-autologin-app` 组。不要为此修改 GitHub Actions 权限。

### 路由器尚未开启 HTTPS

推荐启用 HTTPS 管理。若 `uci -q get uhttpd.main.listen_https` 没有输出，可在路由器上启用 LAN 地址的 HTTPS 监听。例如管理地址为 `192.168.1.1`：

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
- 凭据 URL 通过 curl 配置标准输入传入，不出现在 `ps` 命令行；日志和状态文件不记录密码、会话令牌或完整认证响应；管理界面及状态中的账号完整显示。
- 所有校园网请求使用 `curl --interface` 固定到所选上游设备，并用 `--resolve` 固定到已知网关，避免 VPN/TUN 或污染 DNS 接管认证流量。
- `legacy_http` 会明文传输账号密码，仅在校内网关确实无法使用 HTTPS 时手动启用。无线下还必须配置精确 BSSID，但 BSSID 不是密码学身份验证，风险仍显著高于 TLS。
- bjut-sushe 的旧证书回退采用 curl 的 `--pinnedpubkey` 固定已记录证书的 SPKI；若固件中的 curl/TLS 后端不支持该能力，会安全失败，不会自动降级 HTTP。

## 已知边界

- 离线测试可以验证请求字段、状态机和安全失败逻辑，但无法替代校内三个真实网关的现场测试；首次使用建议执行 `manual` 并检查 `status`/`logread`。
- `lgn` 从所选 IPv6 接口访问 lgn6 的 IPv6 网关；IPv6 发现未通过时，在已确认 IPv4 门户的前提下只提交 IPv4 认证；不会捏造 IPv6 地址。
- LuCI 和 App 协作提供概览、账单导出、账户服务、设备与安全；充值继续使用 App 的当前设备功能。

## 运行测试

在普通 Linux/macOS 开发机（需要 C 编译器、Python 3、Node.js 和 OpenSSL 命令行工具）执行：

```sh
python3 -m unittest -v openwrt/tests/test_openwrt_port.py
python3 openwrt/tests/run_all.py
```

测试详情及覆盖边界见 [TESTING.md](TESTING.md)。

## 协作、后台查询与维护

- 状态包含检测时间和有效期；连接中断或结果过期时，App 与 LuCI 保留上次数据并标记过期。认证会话、IPv4、IPv6 分别显示。
- 登录、注销和切换账号按上游建立任务；同一操作重复点击会合并，页面刷新后仍可查看步骤和结果。超时不自动重复提交认证。
- 账号管理可设置“并发上限”，0 表示不限制。达到上限会选择备用账号；手动切换在注销原账号前先检查空位。
- 后台计费默认关闭，可在设置中开启并设定查询间隔（15 分钟至 24 小时）、余额和流量阈值。优先使用上游当前账号的免密跳转；验证码或查询失败时保留上次数据，不自动充值。相同账号跨上游只汇总一次，未知流量不会按 0 统计。
- 后台提醒使用 PushPlus 设置，每个账号每天最多一条用量提醒；恢复后撤销尚未发送的旧提醒。推送失败不会阻塞认证。
- “路由器备份与更新”可在 App 内或 LuCI 设置中操作。备份含路由账号及推送令牌，保存在路由器私有目录，最多保留 8 份，不加入日志网页软链接。App 自身的设置和账号继续使用设置页的加密导入/导出。
- 更新只读取本项目 GitHub Releases，匹配 Target、架构和包格式，核对两个配套包的 SHA-256，再做包管理器预检查；安装前备份配置并保留旧版本包。断线重连后可继续查看结果，也可回退版本和升级前配置。没有匹配包、回退包或足够空间时停止安装。
