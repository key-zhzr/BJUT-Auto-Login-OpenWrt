# 下载与编译安装包

在仓库的 **Actions → OpenWrt packages → Run workflow** 中编译：

- `package_format`：选择全部格式，或仅 IPK/APK。
- `platform`：选择全部平台，或指定一项。

选择全部格式时，先完成全部 APK，再开始 IPK；仅选一种格式时直接构建该格式。

每项构建都生成 `bjut-autologin` 本体和 `luci-app-bjut-autologin` 管理界面。完成后在任务底部下载对应的 `*-packages` 附件，保留 30 天。构建失败时可下载 SDK 日志。

## 默认编译矩阵

使用官方 SDK，固定 OpenWrt **24.10.8 → IPK**、**25.12.5 → APK**；两个格式分别编译，不转换文件后缀。这里的 APK 是 OpenWrt 安装包，与 Android APK 不同。

| 平台 | 包架构 | 常见设备类型 |
|---|---|---|
| `x86/64` | `x86_64` | x86 软路由 |
| `mediatek/filogic` | `aarch64_cortex-a53` | MT7981/MT7986/MT7988 路由器 |
| `rockchip/armv8` | `aarch64_generic` | Rockchip ARM64 设备 |
| `bcm27xx/bcm2711` | `aarch64_cortex-a72` | Raspberry Pi 4 |
| `qualcommax/ipq60xx` | `aarch64_cortex-a53` | 连我 NN6000 v2 / IPQ6000（仅 25.12 APK） |
| `ipq40xx/generic` | `arm_cortex-a7_neon-vfpv4` | IPQ40xx 路由器 |
| `mvebu/cortexa9` | `arm_cortex-a9_vfpv3-d16` | Marvell Armada 路由器 |
| `ipq806x/generic` | `arm_cortex-a15_neon-vfpv4` | IPQ806x 路由器 |
| `ramips/mt7621` | `mipsel_24kc` | MT7621 路由器 |
| `ath79/generic` | `mips_24kc` | 常见 Atheros MIPS 路由器 |

配置见 [`build-targets.json`](build-targets.json)。修改 SDK 版本时应核对[官方发布目录](https://downloads.openwrt.org/releases/)中的目标及包架构，再执行完整构建。

### 连我 NN6000 v2

在 Actions 中选择 `OpenWrt packages`，将 `platform` 设为 `qualcommax/ipq60xx`，`package_format` 设为 `apk` 或 `all`。构建使用 OpenWrt 25.12.5 官方 SDK，生成本体和 LuCI 两个 APK。官方 SDK 容器标签为 `ghcr.io/openwrt/sdk:qualcommax-ipq60xx-25.12.5`。

OpenWrt 24.10.8 没有官方 IPQ60xx SDK，因此该平台不生成 IPK；选择 `all` 时自动跳过此组合，单独选择 `ipk` 时明确报错。这里构建的是插件安装包，不是 NN6000 v2 的刷机固件；使用 ImmortalWrt、NSS 或其他定制固件时，需先核对系统版本、包格式和 ABI，必要时使用该固件自己的 SDK 编译。

安装前在路由器上执行 `ubus call system board`，查看固件版本及 `release.target`；再用 `opkg print-architecture` 或 `apk --print-arch` 核对包架构。选择与固件匹配的版本、平台和格式。ImmortalWrt 或其他定制固件建议使用其对应 SDK 编译，不能仅根据 CPU 名称判断兼容性。

文件名带有 OpenWrt 版本和平台前缀，避免不同构建的 APK 或通用 LuCI 包互相覆盖。包内部名称保持不变。每个附件的 `.build.json` 记录源码提交、SDK、文件大小及 SHA-256。

## 发布版本

更新两个包的 `PKG_VERSION`，保持一致，再推送 `openwrt-v<版本号>` 标签。例如当前版本对应 `openwrt-v0.1.6`。

标签触发全部 19 项编译。仅在离线检查、全部 SDK 编译、两个包的完整性及校验和核对均通过后，才上传安装包并发布 GitHub Release。Release 包含可直接下载的 IPK/APK、`builds.json` 和 `SHA256SUMS`。已经公开发布的版本不会被重复构建覆盖；修改后使用新版本标签。

手动运行仅生成 Actions 附件，不发布版本。工作流默认令牌权限为只读，只有标签发布任务取得 `contents: write`；不需要额外令牌或 PR 权限。

## 安装

先安装本体，再按需安装 LuCI；依赖由固件自己的软件源提供。下载路径替换为实际文件名：

```sh
# 使用 opkg 的固件
opkg update
opkg install /tmp/openwrt-你的平台-24.10.8-ipk__bjut-autologin_*.ipk
opkg install /tmp/openwrt-你的平台-24.10.8-ipk__luci-app-bjut-autologin_*.ipk

# 使用 apk 的固件：独立安装包尚未配置软件源签名
apk update
apk add --allow-untrusted /tmp/openwrt-你的平台-25.12.5-apk__bjut-autologin-*.apk
apk add --allow-untrusted /tmp/openwrt-你的平台-25.12.5-apk__luci-app-bjut-autologin-*.apk
```

从 Release 下载时，可先在下载目录执行 `sha256sum -c SHA256SUMS` 核对完整性。安装后配置见 [README.md](README.md)。SDK 编译通过不代表已经完成路由器实机安装和校园网认证测试。

## 0.1.6 的版本迁移

路由端从此前独立编号 0.3.0 改为与 App 同步的 0.1.6。已经安装 0.3.0 IPK 的设备可在核对平台与校验和后，使用以下命令保留配置安装：

```sh
opkg --force-downgrade install /tmp/openwrt-*__bjut-autologin_0.1.6-*.ipk
opkg --force-downgrade install /tmp/openwrt-*__luci-app-bjut-autologin_0.1.6-*.ipk
```

APK 仍使用对应固件的包管理器安装。安装后执行 `bjut-autologin version`，应显示 `0.1.6`；LuCI 包也使用相同版本。

当前源码修订号为 13，SDK 生成的安装包标记为 `0.1.6-r13`。`openwrt-v0.1.6-r13` 标签用于独立发布本次修订，保留此前 Release。更新后执行 `/etc/init.d/bjut-autologin restart`，使常驻服务加载新的逻辑。

r13 包含 r12 的 LuCI 计费组件加载修复，并更新计费概览、账单筛选与移动端布局，配色跟随 LuCI 页面。App 协作接口不变。更新后若浏览器仍显示旧界面，请强制刷新页面。
