# 上游基线与迁移对应关系

- 上游仓库：`https://github.com/key-zhzr/BJUT-Auto-Login`
- 审查/迁移基线：`adc028125e46890527a293cd59ffc67366b7222c`
- 上游提交时间：`2026-08-30T02:22:48+08:00`
- 初始迁移版本：`0.2.0`；当前路由端版本：`0.3.0`

主要对应：

| 上游实现 | OpenWrt 端实现 |
|---|---|
| `src-tauri/src/portal_auth.rs` | `bjut-autologin/files/usr/sbin/bjut-autologin` 的三类探测、URL 构造、JSONP 结果状态机 |
| `portal_auth.rs::eportal_encrypt` | `bjut-autologin/src/bjut-codec.c` 的严格 UTF-8 → UTF-16 → XOR `0x16` 编码 |
| `portal_auth/dorm_tls.rs` | 正常 TLS 优先，失败后只允许已记录 SPKI 的 `--pinnedpubkey` 回退 |
| `network_trust.rs::is_campus_local_ip` | `is_campus_ipv4` 的同一网段白名单 |
| `network_trust.rs::campus_wifi_kind` | 精确 `bjut_wifi` 与扫描所得宿舍 SSID 族规则 |
| `PortalRouteContext` / `reqwest::Client::interface` | `ubus` 固定逻辑接口与 `curl --interface`、`--resolve` |

没有迁移计费/充值、桌面托盘、通知、更新器和 Tauri UI；它们不参与路由器维持校园网认证，会增加固件体积、常驻占用和攻击面。

## 0.3.0 同步

- 参考主项目 f37af249d3022d1a0eeffbcb8a2eb8575dce8e1c，并同步 9 月的 lgn 双栈认证修复。
- lgn6 固定解析到 `2001:da8:216:30c9::2` / `::a`，强制 IPv6 并保留 HTTPS 校验。
- IPv6 发现失败允许已验证门户的 IPv4 认证；只有合法 BJUT 前缀的网关观测地址可参与双栈认证。
- 只读门户可尝试第二网关，含密码的登录提交不因超时重复发送。
- 自动合并工作流见 `.github/workflows/openwrt-upstream.yml`，合并检查脚本见 `openwrt/scripts/sync_upstream.py`。

自动同步指 Git 历史与可直接合并的源码更新。桌面 Rust 的新认证逻辑不会自动转换成 shell；涉及后端、安全或冲突的修改会进入待审查分支。允许 Actions 创建 PR 时自动创建，否则可从工作流任务摘要打开差异链接继续审查。合并前需要移植相关逻辑并通过离线测试。

## 独立仓库初始化

仓库：[BJUT-Auto-Login-OpenWrt](https://github.com/key-zhzr/BJUT-Auto-Login-OpenWrt)。

已审查基线：`7e0e7b9bb20c9b59e2cb45988c3a0ffc7bfbe650`。已审阅自 `cb11586` 起的计费、验证码、备份、探测和 Windows 修复；三种门户的认证端点、字段编码与 TLS 策略没有新增变化，不将桌面功能加入路由运行时。路由端协议和上游合并回归已通过。后续自动同步记录见 `UPSTREAM.lock.json`。

保留两个包和上游 Git 历史。桌面检查及发布工作流限制在主项目运行；本仓库执行 OpenWrt 离线检查与每日上游同步。发布安装包时使用与固件一致的 SDK，离线检查不替代 SDK 编译或校园网实测。
