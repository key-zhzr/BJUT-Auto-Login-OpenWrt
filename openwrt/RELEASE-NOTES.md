App 与路由端版本统一为 **0.1.6**。新增多上游、IPv4/IPv6 独立出口、会话与连通性分开判断、mwan3 配合、LuCI 计费查询与 App 协作。

App 在“设置 → 路由协作”连接路由 HTTPS 管理入口，查看状态、登录所选上游和同步勾选账号。路由端仍独立维护校园网。

提供 OpenWrt 24.10.8 的 IPK 与 25.12.5 的 APK，覆盖 x86、ARM64、ARMv7 和 MIPS 共 9 类平台。

按固件版本、平台及包架构选择安装包。先装 `bjut-autologin`，再按需安装 `luci-app-bjut-autologin`；依赖由固件软件源提供。

- [下载、平台与安装说明](https://github.com/key-zhzr/BJUT-Auto-Login-OpenWrt/blob/main/openwrt/BUILDING.md)
- [配置方法](https://github.com/key-zhzr/BJUT-Auto-Login-OpenWrt/blob/main/openwrt/README.md)
- `builds.json` 记录每个包的源码提交、SDK 和 SHA-256；`SHA256SUMS` 可用于下载校验。

这里的 APK 为 OpenWrt 包，不是 Android 应用。构建通过不代表已经完成各设备的校园网实测。

修订 2 修复固件缺少 `cksum` 时的锁冲突和路由错误，LuCI 每 2 秒显示检测步骤。进入计费页面会自动查询各接口的当前账号，优先使用免密跳转，并避免重复统计同一账号余额。构建先完成 APK 再开始 IPK。
