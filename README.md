# BJUT Auto Login · OpenWrt

用于 OpenWrt 路由器的北京工业大学校园网自动认证工具，支持 bjut_wifi、bjut-sushe 和有线 lgn。当前版本 **0.1.6**，由 2026 年 8 月 31 日的路由端源码继续改进。

- 轻量 shell 守护进程与 LuCI 设置界面。
- 多上游分别选择 IPv4 / IPv6 接口、源地址与账号，兼容 mwan3。
- lgn 的 IPv4 + IPv6 联动认证，缺少 IPv6 时可先认证 IPv4。
- 分开判断认证会话与外网探测，避免单个探测地址失败就反复登录。
- LuCI 计费页面查询余额、流量和在线设备，支持图片验证码。
- App 查看路由状态、按上游登录与同步选定账号。

[下载与编译](openwrt/BUILDING.md) · [安装与配置](openwrt/README.md) · [测试方法](openwrt/TESTING.md) · [变更记录](openwrt/CHANGELOG.md) · [上游同步说明](openwrt/UPSTREAM.md)

## 安装

本仓库提供两个包：`bjut-autologin` 本体，以及依赖本体的 `luci-app-bjut-autologin` 管理界面。本体可单独使用。

在 Actions 的 **OpenWrt packages** 中可一键编译主流平台的 IPK/APK；版本标签构建成功后上传至 Releases。请选择与固件版本和架构匹配的包，详见[下载与编译](openwrt/BUILDING.md)。源码保留主项目历史，`openwrt/` 是路由端的代码和文档入口。

## 与主项目同步

上游为 [BJUT-Auto-Login](https://github.com/key-zhzr/BJUT-Auto-Login)。每天安排一次自动检查，也可在 Actions 中手动运行 **OpenWrt upstream sync**：

1. 无冲突的普通更新通过路由端测试后自动合并。
2. 认证、安全或工作流相关更新保留待审查分支，并在任务摘要中提供差异链接，确认后手动合并。
3. 存在冲突时记录文件并保留主分支，绝不自动覆盖。
4. 已存在的待审查分支不会被下一轮任务改写。

桌面与路由是不同实现，自动合并不能替代协议移植与实机校园网测试。路由端提供 LuCI 计费查询；充值等完整校园服务仍使用 App。上游桌面/Android 工作流仅在主项目运行；路由端版本标签使用 `openwrt-v*`。

## 本地验证

```sh
python3 openwrt/tests/run_all.py
python3 openwrt/tests/test_sync_upstream.py
```

SDK 编译及安装前请阅读完整安装文档。普通开发机的离线检查不代表已经通过 OpenWrt 实机认证。

开源第三方工具，非学校官方应用。MIT License。
