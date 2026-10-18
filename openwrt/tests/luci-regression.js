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
        else if (name === 'hidden')
            element.hidden = !!value;
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
let revision = 0, failNext = false, sequence = 0;
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
        return { result: { ...base, module: query.kind === 'action' ? undefined : query.kind, message: query.kind === 'action' ? '操作已完成' : '计费数据已更新', canStop: 1, canReopen: 0, canCancel: 1, installmentFlag: '100', useMoney: '25', packages: [{ id: '2', name: '校园网套餐 · 20 元/月' }, { id: '3', name: '校园网套餐 · 30 元/月' }], questions: [{ id: '1', name: '问题一' }, { id: '2', name: '问题二' }, { id: '3', name: '问题三' }], FLDMINLENGTH: 8, mauth: '1', macs: { columns: ['online', 'mac', 'device', 'lastLoginAt', 'lastIp'], rows: [['在线', 'aabbccddeeff', '测试设备', '2026-10-18', '10.126.19.139']] }, history: { columns: ['loginTime', 'logoutTime', 'ip', 'flow'], rows: [['2026-10-18 12:00', '2026-10-18 13:00', '10.126.19.139', '1024 MB']] } }, sessionsAvailable: true, sessions: [{ sessionIndex: '0', ip: '10.126.19.139', mac: 'aabbccddeeff', useTime: '3600' }] };
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
const modules = { baseclass: LuCIBase, view: LuCIBase, rpc, request, E, _, L, ui: { showModal: () => { }, hideModal: () => { }, addNotification: () => { } } };
async function load(name, path) {
    const source = await (await fetch('../luci-app-bjut-autologin/htdocs/luci-static/resources/' + path + '.js')).text();
    const Module = new Function(...Object.keys(modules), source)(...Object.values(modules));
    if (!(Module?.prototype instanceof LuCIBase)) throw new TypeError(path + ' factory yields invalid constructor');
    modules[name] = new Module();
    return modules[name];
}
const bjut = await load('bjut', 'bjut-autologin/workbench');
await load('client', 'bjut-autologin/client');
await load('records', 'bjut-autologin/records');
await load('BillingTools', 'bjut-autologin/billing-tools');
const views = {};
for (const view of ['overview', 'billing', 'diagnostics', 'logs'])
    views[view] = await load('currentView', 'view/bjut-autologin/' + view);
const titles = { overview: '控制台', billing: '计费系统', diagnostics: '网络诊断', logs: '运行日志' };
let generation = 0;
async function open(view) { const current = ++generation; document.getElementById('heading').textContent = titles[view]; document.querySelectorAll('#tabs button').forEach(button => button.classList.toggle('active', button.dataset.view === view)); const data = await views[view].load(); if (current !== generation)
    return; const root = views[view].render(data); document.getElementById('content').replaceChildren(root); bjut.disclosures(root); }
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
        Array.from(document.querySelectorAll('.bj-tabs button')).find(b => b.textContent === '设备与安全').click();
        await wait(() => document.getElementById('content').textContent.includes('已绑定设备'));
        note('通过：在线设备、MAC 和无感认证');
        await open('logs');
        assert(document.querySelector('.bj-log').textContent.includes('[info]'), '日志没有显示');
        note('通过：信息级日志展示');
        assert(getComputedStyle(document.documentElement).scrollbarGutter.includes('both-edges'), '滚动条影响居中');
        note('通过：滚动条对称预留');
        note('全部通过');
        await open('overview');
    }
    catch (error) {
        note('失败：' + String(error));
    }
};
document.getElementById("run-router-qa").disabled = false;
