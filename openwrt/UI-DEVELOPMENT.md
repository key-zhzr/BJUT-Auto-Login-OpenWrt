# LuCI UI 开发与调试指引

更新于 2026-10-20；按路由端 `dd557f1` / 0.1.6-r12 核对。App 侧配套说明在主项目的 `docs/ui-development.md`。

## 1. 本机目录与离线启动

本机路由仓库为 `/Users/keyzhzr/Documents/BJUT-AL/openwrt-ready.local`，与父目录 App 是独立 Git 仓库。只负责 LuCI 时，从这里进入，不要误改仓库根部保留的旧 App 源码。

```sh
cd /Users/keyzhzr/Documents/BJUT-AL/openwrt-ready.local
python3 -m http.server 1431 --bind 127.0.0.1 --directory openwrt
```

打开 `http://127.0.0.1:1431/tests/luci-regression.html`。这是实际 LuCI 模块的浏览器模拟页，不要求安装 OpenWrt、LuCI、Node 或连接真实路由器。

| 控件/输出 | 选择器 |
| --- | --- |
| “检查刷新与功能” | `#run-router-qa`（初始化完成后才可点击） |
| 结果 | `#router-qa-results` |
| 隐藏验收面板 | `#hide-router-qa` |
| 当前页面内容 | `#content` |
| 页面切换 | `#tabs button[data-view]` |

最终结果应有“全部通过”，没有“失败”。截图前隐藏验收面板。分别用桌面宽度和实际 390px 移动视口检查；有长字段时再看 320px。

## 2. 模拟页覆盖与限制

入口是 [`tests/luci-regression.html`](tests/luci-regression.html) 和 [`tests/luci-regression.js`](tests/luci-regression.js)。JS 加载包中的真实模块，只替换 LuCI 基础对象和 rpcd 返回值：

- `status`、`accounts`、`ports`：四条上游、两组账号及端口计数。
- `server(method,args)`：模拟 dashboard、日志、认证操作、计费任务及轮询。
- `failNext`：一次 dashboard 请求失败，检查后续是否恢复。
- `tickets`：模拟计费查询、记录、账户服务和设备操作的任务结果。
- `LuCIBase` / `load()`：检查模块工厂返回 baseclass 子类，再导入其实例。

目前载入 **overview、billing、diagnostics、logs 四个视图**。账号管理和设置页使用真实 LuCI 的表单/弹窗机制，尚未被此模拟页覆盖；Argon 等主题的外壳、全局 CSS、缓存和路由器性能也未模拟。不要把四页模拟通过写成六页已经实机验收。

需要新增错误、长账号、空列表、加载进度或离页场景时，扩展 fixture / `server()`。这里的登录、注销、套餐等操作只改变本地模拟数据；不要把整套自动操作直接拿到真实路由器执行。

## 3. 修改位置

以下路径从路由仓库根目录起算：

| 范围 | 文件 |
| --- | --- |
| 控制台/端口卡片 | `openwrt/luci-app-bjut-autologin/htdocs/luci-static/resources/view/bjut-autologin/overview.js` |
| 账号管理 | 同目录 `accounts.js` |
| 计费容器、概览与 tab | 同目录 `billing.js` |
| 网络诊断、日志、设置 | 同目录 `diagnostics.js`、`logs.js`、`config.js` |
| 共用样式、端口 DOM、状态文字、动画 | `openwrt/luci-app-bjut-autologin/htdocs/luci-static/resources/bjut-autologin/workbench.js` |
| 请求封装与刷新生命周期 | 同目录 `client.js` |
| 账单、日期与记录 UI | 同目录 `records.js` |
| 共享计费控件（生成文件） | 同目录 `billing-tools.js` |
| LuCI 菜单/路由 | `openwrt/luci-app-bjut-autologin/root/usr/share/luci/menu.d/luci-app-bjut-autologin.json` |
| rpcd 权限 | `openwrt/luci-app-bjut-autologin/root/usr/share/rpcd/acl.d/luci-app-bjut-autologin.json` |
| 后端方法清单、参数与任务分派 | `openwrt/bjut-autologin/files/usr/libexec/rpcd/bjut-autologin` |
| 计费执行器 | `openwrt/bjut-autologin/files/usr/libexec/bjut-billing` |

`workbench.js` 的样式是字符串内嵌 CSS，主体限定在 `.bjut-workbench`；先查看已有规则再加覆盖，避免污染 LuCI 外壳。控制台、账号、计费、诊断、日志向 App 风格靠拢；设置可以继续使用 LuCI 表单样式。

## 4. LuCI 模块契约：不要用普通 ESM 文件替换

视图沿用 LuCI 的 require 指令和 `view.extend()`：

```js
'use strict';
'require view';
'require bjut-autologin.client as client';
'require bjut-autologin.workbench as bjut';

return view.extend({
  handleSave: null,
  handleSaveApply: null,
  handleReset: null,
  load: function() { return client.call('dashboard', {}); },
  render: function(data) {
    return E('section', { 'class': 'bjut-workbench' }, [
      bjut.style(),
      E('p', {}, _('路由器状态已读取'))
    ]);
  }
});
```

共用模块返回 `baseclass.extend({...})`。真实 LuCI 会校验工厂返回的类，并实例化后作为依赖注入；不是直接返回任意对象、ES class 或 `export default`。

共享计费模块的使用方式是 `BillingTools.create(root, options)`，不是 `new BillingTools(...)`。此前直接返回 ES class 引发了真实页面的 `factory yields invalid constructor`；纯语法检查发现不了这一点。

快速检查这个契约：

```sh
node openwrt/tests/test_luci_module_contract.cjs
```

## 5. 已有请求接口

优先沿用 `client.call(method,args,timeout)`。它使用 LuCI 已登录会话向 `rpc.getBaseURL()` 发送 JSON-RPC，调用对象为 `bjut-autologin`。默认单次超时 5000ms，禁用请求批处理，避免慢计费任务阻塞状态读取。

不要在视图里保存管理密码或自行创建另一套登录/轮询客户端。账号管理、设置中已有的 `rpc.declare(...)` 也应保持与后端清单对应。

| 方法组 | 用途 |
| --- | --- |
| `dashboard` | 同一次读取 status、ports、accounts；控制台优先使用 |
| `status`、`ports`、`accounts`、`logs`、`settings` | 分别读取运行信息 |
| `login`、`logout`、`switch_account` | 按 uplink 进行认证操作 |
| `account_set`、`account_save`、`account_delete`、`account_move`、`sync_accounts` | 账号管理 |
| `save_settings`、`uplink_save`、`uplink_delete` | 设置及上游管理 |
| `billing_start`、`billing_details`、`billing_records` | 启动概览、服务/设备、记录查询，返回 ticket |
| `billing_poll` | 读取任务状态、进度和结果 |
| `billing_captcha` | 刷新或提交用户输入的图片验证码 |
| `billing_action` | 计费业务操作，和普通查询分开处理 |

完整参数以 rpcd 文件开头的 `list` 分支为准，可在真实路由器上只读查看：

```sh
ubus -v list bjut-autologin
```

路由计费任务需要当前管理会话的 `owner`。LuCI 传入 `L.env.sessionid`，原生 App 的转发层自行注入 owner，并核对 ticket。不要在 UI 中生成固定 owner，不要跨管理员、上游或账号复用任务和结果。

App 路由转发接口是 `invoke('router_request',{operation,args})`，不是直接拿 LuCI 的本地变量使用；它的 operation/字段白名单位于主项目 `src-tauri/src/router_control.rs`。增加后端字段时还需要同步类型和该白名单，不能只让 UI 发送新字段。

## 6. 刷新与动画约定

复用 `client.watch(root, refresh, interval)`，不要为每个卡片另开 setInterval。它会在 root 挂载后启动，离开页面移除 root 后清理，隐藏页面时暂停请求，并在重新聚焦/联网时继续。控件获得焦点不能成为整页停止刷新的理由。

- 控制台目前检测期间约每 1 秒刷新，其余约 2 秒；慢请求后不会无限积压重复调用。
- 复用 keyed DOM，只更新变化文字，保留账号选择、输入草稿、展开状态和滚动位置。
- 涉及内容高度改变时使用 `bjut.resize(element, update)`；details 交互接入 `bjut.disclosures(root)`，进入效果沿用 `.bj-enter`。
- 快速反向展开/收起时取消旧动画并恢复 overflow；保留 `prefers-reduced-motion`。
- 计费按上游查询，但余额/总流量/剩余流量按账号去重；查询期间逐项显示已完成内容。
- 路由端不显示充值；保留现有概览、用量与账单、账户服务、设备与安全。账号编号完整显示，停用仅影响自动登录顺序。
- 用户可见协议文字统一 `bjut-sushe`、`bjut_wifi`、`lgn`，不显示内部 Type 编号。

## 7. 共享计费控件的生成

必须从当前 **App 仓库**修改 `src/router-billing-tools.ts`，然后运行它的生成器：

```sh
cd /Users/keyzhzr/Documents/BJUT-AL
node scripts/build-router-billing-ui.mjs /Users/keyzhzr/Documents/BJUT-AL/openwrt-ready.local

cd /Users/keyzhzr/Documents/BJUT-AL/openwrt-ready.local
node openwrt/tests/test_luci_module_contract.cjs
git diff -- openwrt/luci-app-bjut-autologin/htdocs/luci-static/resources/bjut-autologin/billing-tools.js
```

生成物要与对应 App 源码分别交付到两个仓库。路由器运行时不需要 Node。上游自动同步对共享源码/生成器变化保留待审查分支，不会自动把 Rust 协议翻译为 shell，也不应为 UI 任务扩大 Actions 权限。详见 [上游同步说明](UPSTREAM.md)。

## 8. 实机只读调试与预览部署

路由器默认地址可先按用户提供的局域网地址填写，不把用户管理密码写进文档、截图、脚本或命令行参数。当前是否在同一局域网、是否安装了插件，需要现场确认。

安装特征入口：`/.well-known/bjut-autologin.json`。这是发现用途的公开元数据，不是管理 API；字段包括 product、apiVersion、version、revision、routerId、features 和 apiPath。

```sh
# 开发机，只读取安装特征，不提交管理凭据。
BJUT_ROUTER_URL=http://192.168.1.1
curl --fail --max-time 3 "$BJUT_ROUTER_URL/.well-known/bjut-autologin.json"

# 路由器 shell 中，只读查看接口和运行状态。
ubus -v list bjut-autologin
bjut-autologin status
logread -e bjut-autologin
```

真实页面是 `http(s)://路由器地址/cgi-bin/luci/admin/network/bjut-autologin/overview`，末尾可换为 `accounts`、`billing`、`diagnostics`、`logs`、`config`。登录后浏览器开发者工具可查看 Console 和 `/ubus` 请求；截图/导出网络记录前检查是否带有 Cookie、管理令牌或账号数据。

只替换 UI 资源时，安装位置为 `/www/luci-static/resources/` 下对应目录。先备份准备改动的文件，再复制这几份资源即可预览；不需要为普通 JS/CSS 修改重启网络。菜单或 ACL 改动另按 LuCI/rpcd 的安装流程验证，不作为纯外观改动顺带部署。

更新 JS 后真实浏览器可能仍使用旧缓存。先核对路由器上的文件，再强制刷新/临时关闭开发者工具缓存；验收后恢复。不要因为旧脚本报错就修改协议或关闭证书验证。

## 9. 检查与交付

```sh
node openwrt/tests/test_luci_module_contract.cjs
python3 openwrt/tests/run_all.py
python3 openwrt/tests/test_sync_upstream.py
```

完整检查需要 Python 3、Node、Dash、OpenSSL、C 编译器及 ASan/UBSan，可能运行数分钟。它们不替代浏览器中的“检查刷新与功能”，也不替代真实 LuCI 主题中的六页验收。更多见 [测试方法](TESTING.md)。

安装包/SDK 构建见 [编译说明](BUILDING.md)：当前两个包共同使用 0.1.6-r12，APK 先于 IPK 编译。这里的 APK 是 OpenWrt 包，不是 Android App；纯 UI 修改不需要自行更换公开标签或发布版本。

交接时列出改动文件、App 共享源与生成物是否都已更新、执行过的检查、实机是否实际部署、截图和剩余限制。不要把旧验收图或 mock 成功结果描述为新代码已经在实际路由器/手机验证。
