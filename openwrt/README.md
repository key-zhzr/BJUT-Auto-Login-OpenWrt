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
- `curl`、`jsonfilter` 与约 10 KiB 级别的 `bjut-codec` 仅在检测/认证时短暂启动。
- 接口 `ifup` 事件立即触发一次检查，平时按设定间隔低频检测；失败后指数退避。
- LuCI 页面仅在管理员打开时运行，不属于后台进程。

## 源码目录

- `bjut-autologin/`：核心包，包含认证脚本、微型 UTF-8/UTF-16 编码器、UCI 默认配置、`procd` 服务和 `netifd` hotplug 脚本。
- `luci-app-bjut-autologin/`：可选 LuCI JavaScript 配置页，只授予 UCI 读写和运行状态文件读取权限，不授予任意命令执行权限。
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

生成的 IPK/APK 位于 SDK 的 `bin/packages/` 或 `bin/targets/` 下。核心包会依赖 `curl`、`ca-bundle`、`rpcd-mod-iwinfo`、`jshn` 和 `jsonfilter`；`rpcd-mod-iwinfo` 同时兼容传统无线脚本和不提供独立 `iwinfo` 命令的新版 `wifi-scripts-ucode`。

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

关键项：

- `network` 必须是接入校园网的逻辑上游接口，通常是 `wwan` 或 `wan`，不能填 `lan`。
- `device` 通常留空，由 `ubus` 的 `l3_device` 自动取得；多 WAN/特殊中继情况下可写实际 Linux 设备名。
- `login_type=auto` 会根据传输类型、SSID 提示及只读门户响应选择协议；也可固定为 `type1`、`type2` 或 `type3`。
- `expected_ssid`/`expected_bssid` 可把凭据限制到精确无线网络。安全模式下 BSSID 可选；`legacy_http` 的无线使用强制要求精确 BSSID。
- 多个 `account` 按 UCI 文件顺序尝试。只有网关明确返回 `result=0` 才切换账号；超时、TLS 错误或无法解析的响应会停止轮换，以免重复认证。

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

`manual` 会立即检测并绕过离线确认次数/冷却计时，但仍不会绕过接口、校园网地址、协议探测、SSID/BSSID 与 TLS 安全检查。

运行状态只写入 `/var/run/bjut-autologin/status.json`，重启后自动清空，不写闪存日志。状态中的账号已脱敏。

## 安全说明

- 密码因 OpenWrt UCI 的性质以明文保存在 `/etc/config/bjut-autologin`；包会把文件权限设为 `0600`。能取得路由器 root 或完整 LuCI 配置权限的用户仍可读取密码。
- 凭据 URL 通过 curl 配置标准输入传入，不出现在 `ps` 命令行；日志和状态文件不记录密码、完整用户名或完整认证响应。
- 所有校园网请求使用 `curl --interface` 固定到所选上游设备，并用 `--resolve` 固定到已知网关，避免 VPN/TUN 或污染 DNS 接管认证流量。
- `legacy_http` 会明文传输账号密码，仅在校内网关确实无法使用 HTTPS 时手动启用。无线下还必须配置精确 BSSID，但 BSSID 不是密码学身份验证，风险仍显著高于 TLS。
- Type 1 的旧证书回退采用 curl 的 `--pinnedpubkey` 固定已记录证书的 SPKI；若固件中的 curl/TLS 后端不支持该能力，会安全失败，不会自动降级 HTTP。

## 已知边界

- 离线测试可以验证请求字段、状态机和安全失败逻辑，但无法替代校内三个真实网关的现场测试；首次使用建议执行 `manual` 并检查 `status`/`logread`。
- `lgn` Type 3 使用同一物理接口访问 lgn6 的 IPv6 网关；IPv6 发现未通过时，在已确认 IPv4 门户的前提下只提交 IPv4 认证；不会捏造 IPv6 地址。
- 计费中心、充值、系统通知和桌面图形界面没有迁入路由器端；这些功能会显著扩大依赖和攻击面，也不属于路由器维持联网所必需的功能。

## 运行测试

在普通 Linux/macOS 开发机（需要 C 编译器、Python 3、Node.js 和 OpenSSL 命令行工具）执行：

```sh
python3 -m unittest -v openwrt/tests/test_openwrt_port.py
python3 openwrt/tests/run_all.py
```

测试详情及覆盖边界见 [TESTING.md](TESTING.md)。
