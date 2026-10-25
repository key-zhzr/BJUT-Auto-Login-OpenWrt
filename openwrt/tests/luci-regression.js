// Load the actual LuCI modules, injecting only synthetic rpcd and LuCI primitives.
// No router/campus address or user credential is contacted by this harness.
Object.defineProperty(document, 'hidden', { configurable: true, value: false });
const E = (tag, attrs = {}, children = []) => {
    if (typeof attrs === 'string' || Array.isArray(attrs) || attrs instanceof Node) {
        children = attrs;
        attrs = {};
    }
    const element = document.createElement(tag);
    for (const [name, value] of Object.entries(attrs || {})) {
        if (typeof value === 'function')
            element.addEventListener(name, value);
        else if (['hidden', 'checked', 'disabled', 'selected'].includes(name))
            element[name] = !!value;
        else if (value != null)
            element.setAttribute(name, String(value));
    }
    for (const child of Array.isArray(children) ? children : [children])
        if (child != null)
            element.append(child instanceof Node ? child : document.createTextNode(String(child)));
    return element;
};
const _ = (text) => text;
const status = { apiVersion: 1, version: '0.1.6', capabilities: ['ports', 'billing', 'billing_actions', 'logs', 'settings', 'uplink_actions'], uplinks: Array.from({ length: 4 }, (_, i) => ({ id: `dorm_${i}`, network: `wan${i + 1}4`, network6: `wan${i + 1}6`, device: i === 3 ? 'eth1.41' : `lan${i + 3}`, ipv4: `10.126.${i + 19}.139`, ipv6: `2001:db8:${i + 1}::1`, state: 'online', message: '认证会话有效，互联网连接正常', session: 'online', account: `2500000${i % 2 + 1}`, internet4: 'reachable', internet6: 'reachable', route4: 'managed', route6: 'managed', updated_at: 1792252800, checking: 0, check_message: '' })) };
const accounts = { accounts: [{ id: 'account1', user: '25000001', enabled: 1, hasPassword: 1, loginType: 'bjut-sushe' }, { id: 'account2', user: '25000002', enabled: 0, hasPassword: 1, loginType: 'lgn' }] };
const ports = { ports: status.uplinks.map((item, i) => ({ uplink: item.id, device: item.device, linkUp: 1, speedMbps: i === 3 ? '2500' : '1000', txBytes: String(50000000000 + i * 1000000000), rxBytes: String(70000000000 + i * 3000000000) })) };
let revision = 0, failNext = false, sequence = 0, pushplusSeq = 0, pushplusMode = 'HoldQueued';
let pushplusState = { state: 'idle', enabled: 1, configured: 1, sequence: 0, updatedAt: 0, httpStatus: '', apiCode: '', pending: 0, cooldownRemaining: 0, delivered: 0, deliverySemantics: 'accepted_not_delivered', message: '尚未发送测试消息；点击发送测试消息后可查看排队、HTTP/业务码或受理状态。' };
const calls = [];
const tickets = new Map();
async function server(method, args = {}) {
    calls.push({ method, args, at: performance.now() });
    await new Promise(r => setTimeout(r, 35));
    if (failNext && method === 'dashboard') {
        failNext = false;
        throw new Error('模拟一次请求超时');
    }
    if (method === 'dashboard') {
        revision++;
        ports.ports.forEach(p => p.txBytes = String(Number(p.txBytes) + 2048));
        return { status, accounts, ports };
    }
    if (method === 'status')
        return status;
    if (method === 'accounts')
        return accounts;
    if (method === 'ports')
        return ports;
    if (method === 'traffic') {
        const day = (offset) => new Date(Date.now() + 8 * 3600000 - offset * 86400000).toISOString().slice(0, 10);
        return { accounts: [{ account: '25000001', updatedAt: Math.floor(Date.now() / 1000), remainingFlow: '30720', devices: [{ mac: 'AA-BB-CC-DD-EE-FF', ip: '10.126.19.139', usedFlowMb: '512.5' }] }], history: [
            { day: day(0), account: '25000001', device: 'device1', label: 'AA-BB-CC-DD-EE-FF', usedMb: 1024, sampledSeconds: 3600 },
            { day: day(1), account: '25000001', device: 'device1', label: 'AA-BB-CC-DD-EE-FF', usedMb: 1024, sampledSeconds: 3600 },
            { day: day(35), account: '25000001', device: 'device1', label: 'AA-BB-CC-DD-EE-FF', usedMb: 2048, sampledSeconds: 3600 },
            { day: day(0), account: '25000002', device: 'device2', label: '11-22-33-44-55-66', usedMb: 4096, sampledSeconds: 3600 },
        ] };
    }
    if (method === 'account_set') {
        const target = accounts.accounts.find(a => a.id === args.account);
        if (target) target.enabled = args.enabled === '1' ? 1 : 0;
        return { state: 'ready', message: '路由器设置已保存' };
    }
    if (method === 'account_move') {
        const idx = accounts.accounts.findIndex(a => a.id === args.account);
        const swap = args.direction === 'up' ? idx - 1 : idx + 1;
        if (idx >= 0 && swap >= 0 && swap < accounts.accounts.length) {
            const [item] = accounts.accounts.splice(idx, 1);
            accounts.accounts.splice(swap, 0, item);
        }
        return { state: 'ready', message: '路由器设置已保存' };
    }
    if (method === 'account_save') {
        if (args.account) {
            const target = accounts.accounts.find(a => a.id === args.account);
            if (target) {
                target.user = args.username;
                target.enabled = args.enabled === '1' ? 1 : 0;
                target.loginType = args.login_type || 'auto';
                target.maxSessions = Number(args.max_sessions || 0);
            }
        } else {
            accounts.accounts.push({ id: 'account' + (accounts.accounts.length + 1), user: args.username, enabled: args.enabled === '1' ? 1 : 0, hasPassword: 1, loginType: args.login_type || 'auto', maxSessions: Number(args.max_sessions || 0) });
        }
        return { state: 'ready', message: '路由器设置已保存' };
    }
    if (method === 'account_delete') {
        const idx = accounts.accounts.findIndex(a => a.id === args.account);
        if (idx >= 0) accounts.accounts.splice(idx, 1);
        return { state: 'ready', message: '路由器设置已保存' };
    }
    if (method === 'pushplus_test') {
        pushplusSeq++;
        pushplusState = { state: 'queued', enabled: 1, configured: 1, sequence: pushplusSeq, updatedAt: Math.floor(Date.now() / 1000), httpStatus: '', apiCode: '', pending: 1, cooldownRemaining: 0, delivered: 0, deliverySemantics: 'accepted_not_delivered', message: '测试消息排队发送中，等待后台连接 PushPlus。' };
        return { state: 'ready', message: '测试消息已加入发送队列；PushPlus 异步投递，已受理不等于已送达，可查看测试状态', testStatus: { ...pushplusState } };
    }
    if (method === 'pushplus_status') {
        if (pushplusMode === 'Fail500' && pushplusSeq > 0) {
            pushplusState = { state: 'error', enabled: 1, configured: 1, sequence: pushplusSeq, updatedAt: Math.floor(Date.now() / 1000), httpStatus: '200', apiCode: '500', pending: 1, cooldownRemaining: 58, delivered: 0, deliverySemantics: 'accepted_not_delivered', message: '推送请求失败（HTTP 200 / 业务码 500），将在冷却后重试。' };
        } else if (pushplusMode === 'Accept200' && pushplusSeq > 0) {
            pushplusState = { state: 'accepted', enabled: 1, configured: 1, sequence: pushplusSeq, updatedAt: Math.floor(Date.now() / 1000), httpStatus: '200', apiCode: '200', pending: 0, cooldownRemaining: 55, delivered: 0, deliverySemantics: 'accepted_not_delivered', message: 'PushPlus 已受理（HTTP 200 / 业务码 200）；平台异步投递，已受理不等于已送达。' };
        }
        return { ...pushplusState };
    }
    if (['login', 'logout', 'switch_account'].includes(method)) {
        const item = status.uplinks.find(u => u.id === args.uplink);
        item.state = method === 'logout' ? 'logged_out' : 'online';
        if (args.account)
            item.account = accounts.accounts.find(a => a.id === args.account).user;
        item.updated_at++;
        return { state: 'loading', message: '操作已完成' };
    }
    if (method === 'logs')
        return { text: `[2026-10-18 12:00:00] [info] [dorm_0/lan3] 开始检测\n[2026-10-18 12:00:00] [info] [dorm_0/lan3] 认证会话有效，IPv4 / IPv6 可用\n[2026-10-18 12:00:01] [info] [dorm_1/lan4] 账号 25000002 认证成功\n[2026-10-18 12:00:01] [info] [service] 本地模拟刷新 ${revision}` };
    if (['billing_start', 'billing_details', 'billing_records', 'billing_action'].includes(method)) {
        const ticket = String(++sequence).padStart(32, '0');
        const index = Number(args.uplink?.split('_')[1] || 0);
        tickets.set(ticket, { kind: method === 'billing_details' ? args.module : method === 'billing_records' ? 'records' : method === 'billing_action' ? 'action' : 'overview', account: `2500000${index % 2 + 1}` });
        return { ticket, state: 'loading' };
    }
    if (method === 'billing_poll') {
        const query = tickets.get(args.ticket);
        const base = { state: 'ready', account: query.account, message: '计费数据已更新', percent: 100 };
        if (query.kind === 'overview')
            return { result: { ...base, balance: '42.125', totalFlow: '40960', remainingFlow: '30720', accountStatus: '正常', package: '校园网套餐' }, sessionsAvailable: true, sessions: [{ sessionIndex: '0', ip: '10.126.19.139', ipv6: '2001:db8::1', mac: 'aabbccddeeff', useTime: '3600' }] };
        if (query.kind === 'records')
            return { result: { ...base, kind: args.kind || 'usage', columns: ['loginTime', 'flow'], rows: [['2026-10-18 12:00', '1024']], total: 1, page: 1 } };
        return { result: { ...base, module: query.kind === 'action' ? undefined : query.kind, message: query.kind === 'action' ? '操作已完成' : '计费数据已更新', canStop: 1, canReopen: 0, canCancel: 1, installmentFlag: '100', useMoney: '25', currentPackageId: '2', currentPackage: '校园网套餐', packageDetail: '每月 20 元包含 120 GB 流量，超出后按实际用量计费', packages: [{ id: '2', name: '校园网套餐', description: '每月 20 元包含 120 GB 流量，超出后按实际用量计费' }, { id: '3', name: '校园网畅享套餐', description: '每月 30 元包含 180 GB 流量，超出后按实际用量计费' }], questions: [{ id: '1', name: '问题一' }, { id: '2', name: '问题二' }, { id: '3', name: '问题三' }], FLDMINLENGTH: 8, mauth: '1', macs: { columns: ['online', 'mac', 'device', 'lastLoginAt', 'lastIp'], rows: [['在线', 'aabbccddeeff', '测试设备', '2026-10-18', '10.126.19.139']] }, history: { columns: ['loginTime', 'logoutTime', 'ip', 'flow'], rows: [['2026-10-18 12:00', '2026-10-18 13:00', '10.126.19.139', '1024 MB']] } }, sessionsAvailable: true, sessions: [{ sessionIndex: '0', ip: '10.126.19.139', mac: 'aabbccddeeff', useTime: '3600' }] };
    }
    return { state: 'ready' };
}
const L = { env: { sessionid: '1'.repeat(32) } };
const rpc = { getBaseURL: () => '/mock-ubus', getSessionID: () => L.env.sessionid, declare: (declaration) => (...values) => server(declaration.method, Object.fromEntries((declaration.params || []).map((key, i) => [key, values[i]]))) };
const request = { post: async (_url, body, _options) => ({ ok: true, json: () => ({ jsonrpc: '2.0', id: body.id, result: [0, awaited.get(body.id)] }) }) };
const awaited = new Map();
request.post = async (_url, body, _options) => { const result = await server(body.params[2], body.params[3]); awaited.set(body.id, result); return { ok: true, json: () => ({ jsonrpc: '2.0', id: body.id, result: [0, result] }) }; };
// LuCI validates module factories and imports an instance of the returned class.
// An identity mock of extend() hides invalid native-class exports until deployment.
class LuCIBase {
    static extend(methods) { class Module extends this {} Object.assign(Module.prototype, methods); return Module; }
}
const mockUciSections = {
    service: [{ '.name': 'main', '.type': 'service', enabled: '1', transport: 'auto', login_type: 'auto', compatibility: 'secure', strict_network: '1', interval: '20', timeout: '3', offline_confirmations: '2', max_backoff: '300', credential_cooldown: '600', post_login_delay: '2', online_url: 'http://connect.rom.miui.com/generate_204', online_code: '204', log_level: 'info', log_target: 'system', managed_routes: '1', mwan3: '1', pushplus_enabled: '1', pushplus_online: '1', pushplus_failure: '1', pushplus_delay: '60', pushplus_interval: '3600', prefer_remaining_flow: '0', traffic_monitor: '1', billing_background: '0' }],
    uplink: [
        { '.name': 'dorm_0', '.type': 'uplink', enabled: '1', network: 'wan14', network6: 'wan16', device: 'lan3', transport: 'ethernet', login_type: 'type1', accounts: ['account1', 'account2'] },
        { '.name': 'dorm_1', '.type': 'uplink', enabled: '1', network: 'wan24', network6: 'wan26', device: 'lan4', transport: 'ethernet', login_type: 'type1', accounts: ['account2'] }
    ]
};
const uci = {
    load: async () => mockUciSections,
    sections: (_pkg, type, cb) => {
        const list = type === 'account'
            ? accounts.accounts.map(a => ({ '.name': a.id, '.type': 'account', username: a.user, enabled: a.enabled ? '1' : '0' }))
            : (mockUciSections[type] || []);
        list.forEach(item => cb && cb(item));
        return list;
    }
};
class FormOption extends LuCIBase {
    constructor(map, section, name, title, description) {
        super();
        this.map = map;
        this.section = section;
        this.option = name;
        this.title = title || name;
        this.description = description || '';
        this.values = [];
        this.deps = [];
        this.readonly = false;
    }
    value(v, label) { this.values.push([v, label || v]); }
    depends(field, val) { this.deps.push([field, val]); }
    cbid(sid) { return `cbid.${this.map.config}.${sid}.${this.option}`; }
    cfgvalue(sid) {
        const all = [...mockUciSections.service, ...mockUciSections.uplink];
        const found = all.find(s => s['.name'] === sid);
        return found && found[this.option] !== undefined ? found[this.option] : this.default;
    }
    renderWidget(sid, _idx, cfgval) {
        const id = this.cbid(sid);
        if (this instanceof FormFlag) {
            const input = E('input', { id, type: 'checkbox' });
            input.checked = String(cfgval ?? this.default ?? '0') === '1';
            return input;
        }
        if (this instanceof FormListValue) {
            const select = E('select', { id, 'class': 'cbi-input-select' }, this.values.map(([v, l]) => E('option', { value: v }, l)));
            if (cfgval !== undefined) select.value = String(cfgval);
            return select;
        }
        if (this instanceof FormButton) {
            return E('button', { id, type: 'button', 'class': 'btn cbi-button', click: () => this.onclick && this.onclick() }, this.inputtitle || this.title);
        }
        const input = E('input', { id, 'class': 'cbi-input-text', type: this.password ? 'password' : 'text', value: cfgval ?? '', placeholder: this.placeholder || '' });
        return input;
    }
}
class FormFlag extends FormOption {}
class FormListValue extends FormOption {}
class FormValue extends FormOption {}
class FormButton extends FormOption {}
class FormSection {
    constructor(map, sectionType, name, title) {
        this.map = map;
        this.sectionType = sectionType;
        this.name = name;
        this.title = title || '';
        this.options = [];
    }
    option(OptionClass, name, title, description) {
        const opt = new OptionClass(this.map, this, name, title, description);
        this.options.push(opt);
        return opt;
    }
}
class FormMap {
    constructor(config, title, description) {
        this.config = config;
        this.title = title;
        this.description = description;
        this.sections = [];
        this.readonly = false;
        this.root = null;
    }
    section(SectionKind, a, b, c) {
        const sec = SectionKind === 'named' ? new FormSection(this, b, a, c) : new FormSection(this, a, '', b);
        sec.kind = SectionKind;
        this.sections.push(sec);
        return sec;
    }
    findElement(attr, val) {
        return this.root ? this.root.querySelector(`[${attr}="${val}"]`) : null;
    }
    async render() {
        const root = E('div', { 'class': 'bjut-workbench bj-config-map' }, [
            E('p', { 'class': 'bj-billing-subtitle' }, this.description)
        ]);
        this.root = root;
        for (const sec of this.sections) {
            const sids = sec.kind === 'named' ? [sec.name] : (mockUciSections[sec.sectionType] || []).map(s => s['.name']);
            const card = E('section', { 'class': 'bj-card' }, [
                E('h3', {}, sec.title),
                sec.description ? E('p', {}, sec.description) : null
            ]);
            for (const sid of sids) {
                const block = E('div', { 'class': 'bj-form', 'data-section-id': sid });
                if (sec.kind !== 'named') block.append(E('h4', {}, sid));
                for (let i = 0; i < sec.options.length; i++) {
                    const opt = sec.options[i];
                    if (opt.modalonly) continue;
                    const widget = opt.renderWidget(sid, i, opt.cfgvalue(sid));
                    block.append(E('div', { 'class': 'cbi-value', 'data-option': opt.option }, [
                        E('label', { 'class': 'cbi-value-title' }, opt.title),
                        E('div', { 'class': 'cbi-value-field' }, [
                            widget,
                            opt.description ? E('p', { 'class': 'cbi-value-description' }, opt.description) : null
                        ])
                    ]));
                }
                card.append(block);
            }
            root.append(card);
        }
        return root;
    }
}
const form = { Map: FormMap, NamedSection: 'named', GridSection: 'grid', Flag: FormFlag, ListValue: FormListValue, Value: FormValue, Button: FormButton };
class NetworkSelect extends FormListValue {
    constructor(map, section, name, title, description) {
        super(map, section, name, title, description);
        ['wan14', 'wan16', 'wan24', 'wan26'].forEach(n => this.value(n, n));
    }
}
const widgets = { NetworkSelect };
let modalNode = null;
const ui = {
    showModal: (title, children) => {
        if (modalNode) modalNode.remove();
        modalNode = E('div', { id: 'luci-modal', 'class': 'bj-card', role: 'dialog', 'aria-label': title }, [
            E('h3', {}, title),
            ...(Array.isArray(children) ? children : [children])
        ]);
        document.body.append(modalNode);
        return modalNode;
    },
    hideModal: () => {
        if (modalNode) {
            modalNode.remove();
            modalNode = null;
        }
    },
    addNotification: (_title, body, severity) => {
        let host = document.getElementById('luci-notifications');
        if (!host) {
            host = E('div', { id: 'luci-notifications', role: 'status' });
            document.body.prepend(host);
        }
        host.replaceChildren(E('div', { 'class': 'bj-notification ' + (severity || 'info') }, body));
    }
};
const modules = { baseclass: LuCIBase, view: LuCIBase, rpc, request, E, _, L, ui, uci, form, widgets };
async function load(name, path) {
    const source = await (await fetch('../luci-app-bjut-autologin/htdocs/luci-static/resources/' + path + '.js')).text();
    const Module = new Function(...Object.keys(modules), source)(...Object.values(modules));
    if (!(Module?.prototype instanceof LuCIBase)) throw new TypeError(path + ' factory yields invalid constructor');
    modules[name] = new Module();
    return modules[name];
}
const bjut = await load('bjut', 'bjut-autologin/workbench');
await load('client', 'bjut-autologin/client');
await load('usage','bjut-autologin/usage-model');
await load('traffic','bjut-autologin/traffic');
await load('records', 'bjut-autologin/records');
await load('BillingTools', 'bjut-autologin/billing-tools');
await load('maintenance', 'bjut-autologin/maintenance');
await load('accountOrder', 'bjut-autologin/account-order');
const views = {};
for (const view of ['overview', 'accounts', 'billing', 'diagnostics', 'logs', 'config'])
    views[view] = await load('currentView', 'view/bjut-autologin/' + view);
const titles = { overview: '控制台', accounts: '账号管理', billing: '计费系统', diagnostics: '网络诊断', logs: '运行日志', config: '设置' };
let generation = 0;
async function open(view) { const current = ++generation; document.getElementById('heading').textContent = titles[view]; document.querySelectorAll('#tabs button').forEach(button => button.classList.toggle('active', button.dataset.view === view)); const data = await views[view].load(); if (current !== generation)
    return; const root = await views[view].render(data); if (current !== generation)
    return; root.dataset.qaView = view; document.getElementById('content').replaceChildren(root); bjut.disclosures(root); }
for (const [id, title] of Object.entries(titles)) {
    const button = E('button', { type: 'button', 'data-view': id, click: () => { void open(id); } }, title);
    document.getElementById('tabs').append(button);
}
await open('overview');
document.getElementById('hide-router-qa').onclick = () => document.getElementById('test-panel').hidden = true;
const wait = async (test, timeout = 7000) => { const end = performance.now() + timeout; while (!test()) {
    if (performance.now() > end)
        throw new Error('等待界面超时');
    await new Promise(r => setTimeout(r, 35));
} };
const assert = (value, message) => { if (!value)
    throw new Error(message); };
document.getElementById('run-router-qa').onclick = async () => {
    const out = document.getElementById('router-qa-results');
    out.textContent = '';
    const note = (s) => out.textContent += s + '\n';
    try {
        await open('overview');
        const selector = document.querySelector('.bj-port select');
        selector.value = 'account2';
        selector.focus();
        const before = revision;
        await wait(() => revision >= before + 2);
        assert(selector === document.querySelector('.bj-port select') && selector.value === 'account2', '刷新替换了操作控件');
        note('通过：控件聚焦期间仍刷新，选择保持不变');
        failNext = true;
        const fault = revision;
        await wait(() => document.querySelector('[role=status]').textContent.includes('超时'));
        await wait(() => revision > fault);
        note('通过：请求失败后自动继续刷新');
        const card = document.querySelector('.bj-port');
        Array.from(card.querySelectorAll('button')).find(b => b.textContent === '注销').click();
        await wait(() => card.textContent.includes('已注销'));
        assert(calls.some(c => c.method === 'logout'), '没有提交所选接口注销');
        Array.from(card.querySelectorAll('button')).find(b => b.textContent === '切换账号').click();
        await wait(() => card.textContent.includes('25000002'));
        assert(calls.some(c => c.method === 'switch_account' && c.args.account === 'account2'), '账号切换不正确');
        note('通过：按接口注销与切换账号');
        await open('accounts');
        assert(document.getElementById('content').textContent.includes('25000001'), '账号列表未加载');
        Array.from(document.querySelectorAll('#content button')).find(b => b.textContent === '下移').click();
        await wait(() => calls.some(c => c.method === 'account_move' && c.args.direction === 'down') && document.querySelector('#content .bj-account-name')?.textContent === '25000002');
        Array.from(document.querySelectorAll('#content button')).find(b => b.textContent === '停用自动登录').click();
        await wait(() => calls.some(c => c.method === 'account_set' && c.args.enabled === '0') && !Array.from(document.querySelectorAll('#content button')).some(b => b.textContent === '停用自动登录'));
        Array.from(document.querySelectorAll('#content button')).find(b => b.textContent === '添加账号').click();
        await wait(() => !!document.getElementById('luci-modal'));
        document.querySelector('#luci-modal input[type="text"]').value = '25000003';
        document.querySelector('#luci-modal input[type="password"]').value = 'fixture-password';
        Array.from(document.querySelectorAll('#luci-modal button')).find(b => b.textContent === '保存').click();
        await wait(() => !document.getElementById('luci-modal') && document.getElementById('content').textContent.includes('25000003'));
        note('通过：账号管理启停、排序与添加编辑弹窗');
        await open('billing');
        const leftOverviewAt = performance.now();
        await new Promise(r => setTimeout(r, 2300));
        assert(!calls.some(c => c.method === 'dashboard' && c.at > leftOverviewAt), '离开页面后旧刷新任务仍运行');
        await wait(() => document.querySelector('.bj-summary').textContent.includes('84.25'));
        note('通过：计费自动查询并按账号去重汇总');
        Array.from(document.querySelectorAll('.bj-tabs button')).find(b => b.textContent === '账户服务').click();
        await wait(() => document.getElementById('content').textContent.includes('消费限额'));
        assert(document.getElementById('content').textContent.includes('预约套餐'), '业务办理缺少套餐');
        note('通过：账户服务和消费保护');
        const packageChoice = document.querySelector('.bj-package-option.selected');
        assert(packageChoice?.querySelector('p')?.textContent.includes('120 GB'), '套餐说明缺失');
        assert(packageChoice.querySelectorAll('.billing-package-badge').length === 2, '当前与下一周期标识缺失');
        const cardBounds = packageChoice.getBoundingClientRect();
        for (const child of packageChoice.children) {
            const bounds = child.getBoundingClientRect();
            assert(bounds.top >= cardBounds.top && bounds.bottom <= cardBounds.bottom, 'LuCI 主题固定按钮高度遮住了套餐说明或周期标识');
        }
        note('通过：LuCI 固定按钮高度下套餐说明和周期标识完整显示');
        Array.from(document.querySelectorAll('.bj-tabs button')).find(b => b.textContent === '设备与安全').click();
        await wait(() => document.getElementById('content').textContent.includes('已绑定设备'));
        note('通过：在线设备、MAC 和无感认证');
        await open('diagnostics');
        assert(document.getElementById('content').textContent.includes('IPv4 通过 · IPv6 通过'), '网络诊断缺少双栈探测结果');
        assert(document.getElementById('content').textContent.includes('固定出口'), '网络诊断缺少出口路由状态');
        Array.from(document.querySelectorAll('#content button')).find(b => b.textContent === '刷新').click();
        await wait(() => document.getElementById('content').textContent.includes('已更新各上游检测结果'));
        assert(!!Array.from(document.querySelectorAll('#content button')).find(b => b.textContent === '导出诊断包'), '缺少导出诊断包按钮');
        note('通过：网络诊断双栈状态与诊断包导出');
        await open('logs');
        assert(document.querySelector('.bj-log').textContent.includes('[info]'), '日志没有显示');
        note('通过：信息级日志展示');
        await open('config');
        assert(document.querySelectorAll('.bj-account-order').length >= 2, '设置页缺少按接口账号顺序控件');
        const pushStatus = document.querySelector('.bj-pushplus-status');
        assert(pushStatus && pushStatus.getAttribute('data-state') === 'idle', 'PushPlus 初始测试状态不正确');
        pushplusMode = 'HoldQueued';
        Array.from(document.querySelectorAll('#content button')).find(b => b.textContent === '发送测试消息').click();
        await wait(() => pushStatus.getAttribute('data-state') === 'queued' && pushStatus.textContent.includes('排队中'));
        pushplusMode = 'Fail500';
        Array.from(pushStatus.querySelectorAll('button')).find(b => b.textContent === '刷新测试状态').click();
        await wait(() => pushStatus.getAttribute('data-state') === 'error' && pushStatus.textContent.includes('HTTP 200') && pushStatus.textContent.includes('业务码 500'));
        pushplusMode = 'Accept200';
        Array.from(pushStatus.querySelectorAll('button')).find(b => b.textContent === '刷新测试状态').click();
        await wait(() => pushStatus.getAttribute('data-state') === 'accepted' && pushStatus.textContent.includes('已受理不等于已送达'));
        note('通过：设置页面与 PushPlus 排队/失败码/已受理状态');
        assert(getComputedStyle(document.documentElement).scrollbarGutter.includes('both-edges'), '滚动条影响居中');
        note('通过：滚动条对称预留');
        await open('overview');
        note('全部通过');
    }
    catch (error) {
        note('失败：' + String(error));
    }
};
document.getElementById("run-router-qa").disabled = false;
