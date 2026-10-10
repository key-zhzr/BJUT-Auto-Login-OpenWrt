提供 OpenWrt 24.10.8 的 IPK 与 25.12.5 的 APK，覆盖 x86、ARM64、ARMv7 和 MIPS 共 9 类平台。

按固件版本、平台及包架构选择安装包。先装 `bjut-autologin`，再按需安装 `luci-app-bjut-autologin`；依赖由固件软件源提供。

- [下载、平台与安装说明](https://github.com/key-zhzr/BJUT-Auto-Login-OpenWrt/blob/main/openwrt/BUILDING.md)
- [配置方法](https://github.com/key-zhzr/BJUT-Auto-Login-OpenWrt/blob/main/openwrt/README.md)
- `builds.json` 记录每个包的源码提交、SDK 和 SHA-256；`SHA256SUMS` 可用于下载校验。

这里的 APK 为 OpenWrt 包，不是 Android 应用。构建通过不代表已经完成各设备的校园网实测。
