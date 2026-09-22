# OpenWrt 端测试说明

测试不使用真实账号，也不会访问校园网。`tests/mocks/curl.sh` 模拟三个门户，只接收程序通过标准输入交给 curl 的 URL；因此还可检查凭据是否意外出现在命令行参数中。

## 自动覆盖矩阵

| 类别 | 覆盖内容 |
|---|---|
| 编码 | 原 Rust 核心的 `dr1005`、`4.2.2`、Base64 固定向量；随机 Unicode、代理对、URL 百分号编码；IPv6 严格解析；非法 UTF-8/超长输入 |
| Type 1 | 正常 TLS、旧宿舍证书 SPKI 固定回退、SNI/Host/固定 IP、`@campus`、本地 IPv4、HTTP 明确启用边界 |
| Type 2 | HTTPS 固定网关、完整 Dr.COM 参数、特殊字符密码、多账号明确拒绝后轮换 |
| Type 3 | `loadUserInfo`、IPv6 发现、动态字段 XOR、主/备固定网关、缺少 IPv6 时仅提交已验证门户的 IPv4 认证；外部 IPv6 前缀不发送；模糊结果不重复提交 |
| 联网状态机 | 已联网快速路径、连续离线确认、登录后复核、指数退避、认证拒绝冷却、手动检查 |
| 失败语义 | 非校园 IP、SSID/BSSID 不匹配、协议/传输不匹配、无门户、门户未就绪、结果未知、超大响应、并发锁和陈旧锁恢复 |
| 隐私 | 密码与完整账号不出现在 curl argv、syslog 和 JSON 状态；状态账号脱敏 |
| 静态检查 | Dash 语法、LuCI JavaScript 编译、菜单/ACL JSON、ACL 无文件执行权限、捕获证书 SPKI 重算、GCC `-fanalyzer`、ASan/UBSan、UTF-8 与尾随空白 |

## 一键运行

开发机需提供 Python 3、可用的 C 编译器、Node.js、OpenSSL、Dash，以及支持 AddressSanitizer/UndefinedBehaviorSanitizer 的编译器运行库。

```sh
python3 openwrt/tests/run_all.py
```

也可只运行协议/状态机测试：

```sh
python3 -m unittest -v openwrt/tests/test_openwrt_port.py
```

## 未伪装为已完成的测试

以下项目必须在用户的实际设备/校园网络执行，当前离线环境无法诚实替代：

1. 用目标固件完全一致的 SDK 交叉编译并安装 IPK/APK。
2. 在 `bjut-sushe`、`bjut_wifi` 和 `lgn` 三种真实网络分别执行一次 `manual`。
3. 验证目标固件 curl 的 TLS 后端支持 `--pinnedpubkey`；不支持时 Type 1 旧证书路径应安全失败。
4. 测量目标路由器的实际 RSS、CPU 唤醒和 24 小时重连表现。

建议现场测试流程：

```sh
bjut-autologin check-config
/etc/init.d/bjut-autologin restart
/etc/init.d/bjut-autologin manual
bjut-autologin status
logread -e bjut-autologin
ps w | grep '[b]jut-autologin'
```

测试账号错误时请等待冷却，不要连续手动重试；真实网关若返回未知结构，应先保存脱敏响应结构再修改解析器，不能把未知结果当作成功。
