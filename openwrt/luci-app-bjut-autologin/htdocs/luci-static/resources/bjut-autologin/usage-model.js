'use strict';
'require baseclass';
// Generated from src/device-usage-model.ts.
function normalizeUsageReport(report) {
    const series = [...(report.series || [])];
    for (const row of report.timeline?.buckets || []) {
        const channel = report.timeline?.channels[row[0]];
        if (!channel || row.length !== 5 || !row.every(Number.isFinite) || ![60, 3600, 86400].includes(row[1]) || row[3] < 0 || row[4] <= 0)
            continue;
        series.push({ ...channel, resolution: row[1], at: row[2], usedMb: row[3], sampledSeconds: row[4] });
    }
    // Scope is enforced by the sampler/API and again here for cached data from
    // an earlier all-device session. Unclassified legacy rows are not local.
    const all = report.scope === 'all';
    return { ...report, timeline: undefined, accounts: (report.accounts || []).map(account => ({ ...account, devices: (account.devices || []).filter(device => all || device.local === true) })), history: (report.history || []).filter(row => all || row.local === true), series: series.filter(row => all || row.local === true) };
}
const usageScales = [
    { value: 'minute', text: '每分钟', seconds: 60, ranges: [3600, 21600, 86400, 172800] },
    { value: '5minutes', text: '每 5 分钟', seconds: 300, ranges: [21600, 86400] },
    { value: '15minutes', text: '每 15 分钟', seconds: 900, ranges: [21600, 86400] },
    { value: 'hour', text: '每小时', seconds: 3600, ranges: [86400, 604800, 2592000] },
    { value: 'day', text: '每天', seconds: 86400, ranges: [604800, 2592000, 7776000, 31536000] },
    { value: 'month', text: '每月', seconds: 0, ranges: [15552000, 31536000] },
];
function usageBucket(at, scale) {
    if (scale === 'month') {
        const date = new Date((at + 28800) * 1000);
        return Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1) / 1000 - 28800;
    }
    const seconds = usageScales.find(item => item.value === scale).seconds;
    return Math.floor((at + 28800) / seconds) * seconds - 28800;
}
function usageRangeLabel(seconds) {
    return seconds < 86400 ? `近 ${seconds / 3600} 小时` : seconds < 15552000 ? `近 ${seconds / 86400} 天` : `近 ${seconds === 31536000 ? 12 : 6} 个月`;
}
function usageInterfaces(points, account = '') {
    const interfaces = new Map();
    for (const point of points)
        if (!account || point.account === account)
            interfaces.set(point.interfaceId, point.interfaceName);
    return [...interfaces].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name, 'zh-CN'));
}
function buildUsageChart(rows, options) {
    const now = options.now ?? Date.now() / 1000;
    const scale = usageScales.find(item => item.value === options.scale);
    const resolution = options.scale === 'month' || scale.seconds >= 86400 ? 86400 : scale.seconds >= 3600 ? 3600 : 60;
    const start = usageBucket(now - options.range, options.scale), end = usageBucket(now, options.scale);
    const times = [];
    for (let at = start; at <= end && times.length < 5000;) {
        times.push(at);
        if (options.scale === 'month') {
            const date = new Date((at + 28800) * 1000);
            at = Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1) / 1000 - 28800;
        }
        else
            at += scale.seconds;
    }
    const index = new Map(times.map((at, i) => [at, i])), curves = new Map();
    let samples = 0, totalMb = 0;
    for (const row of rows) {
        if (row.resolution !== resolution || !Number.isFinite(row.at) || row.at > now || !Number.isFinite(row.usedMb) || row.usedMb < 0 || row.sampledSeconds <= 0 || !Number.isFinite(row.sampledSeconds) || (options.account && row.account !== options.account))
            continue;
        if (options.presentation === 'interfaces' && options.interfaces !== null && !options.interfaces.includes(row.interfaceId))
            continue;
        const i = index.get(usageBucket(row.at, options.scale));
        if (i === undefined)
            continue;
        const id = options.presentation === 'sum' ? 'sum' : row.interfaceId;
        const curve = curves.get(id) || { id, name: options.presentation === 'sum' ? '所有接口合计' : row.interfaceName, points: Array(times.length).fill(null), totalMb: 0 };
        curve.points[i] = (curve.points[i] ?? 0) + row.usedMb;
        curve.totalMb += row.usedMb;
        curves.set(id, curve);
        totalMb += row.usedMb;
        samples++;
    }
    const ordered = [...curves.values()].sort((a, b) => a.name.localeCompare(b.name, 'zh-CN'));
    if (options.mode === 'cumulative')
        for (const curve of ordered) {
            let sum = 0;
            curve.points = curve.points.map(point => point === null ? null : (sum += point));
        }
    return { times, curves: ordered, samples, totalMb };
}
function usageChartCsv(chart, mode) {
    const rows = [['时间（北京时间）', '接口', mode === 'delta' ? '采样新增流量（MB）' : '所选范围累计流量（MB）']];
    chart.times.forEach((at, i) => chart.curves.forEach(curve => {
        if (curve.points[i] !== null)
            rows.push([new Date((at + 28800) * 1000).toISOString().slice(0, 19).replace('T', ' '), curve.name, curve.points[i].toFixed(3)]);
    }));
    return '\uFEFF' + rows.map(row => row.map(value => { const raw = String(value); return `"${(/^[=+\-@]/.test(raw.trimStart()) ? "'" + raw : raw).replaceAll('"', '""')}"`; }).join(',')).join('\r\n');
}
function usageIdentity(source, account, device) {
    return JSON.stringify([source, account, device.mac.replace(/[:-]/g, '').toLowerCase(), device.ip, device.loginAt]);
}
function usageDelta(previous, at, value) {
    if (!/^\d+(\.\d+)?$/.test(value))
        return null;
    const used = Number(value);
    return Number.isFinite(used) && previous && at > previous.at && at - previous.at <= 180 && used >= previous.used ? used - previous.used : null;
}
function flowLabel(value) { return value >= 1024 ? `${(value / 1024).toFixed(2)} GB` : `${value.toFixed(2)} MB`; }
function flowMb(value) {
    const match = value.trim().match(/^(\d+(?:\.\d+)?)\s*(MB|GB|TB)?$/i);
    if (!match)
        return null;
    return Number(match[1]) * ({ MB: 1, GB: 1024, TB: 1048576 }[match[2]?.toUpperCase() || 'MB'] || 1);
}
function forecastUsage(rows, remaining, now = new Date()) {
    const available = flowMb(remaining);
    if (available === null)
        return null;
    const businessNow = new Date(now.getTime() + 8 * 3600000), today = businessNow.toISOString().slice(0, 10);
    const recent = rows.filter(row => row.day >= new Date(businessNow.getTime() - 7 * 86400000).toISOString().slice(0, 10) && row.day <= today && Number.isFinite(row.usedMb) && row.usedMb >= 0 && Number.isFinite(row.sampledSeconds) && row.sampledSeconds > 0);
    const seconds = recent.reduce((sum, row) => sum + row.sampledSeconds, 0), total = recent.reduce((sum, row) => sum + row.usedMb, 0);
    if (new Set(recent.map(row => row.day)).size < 2 || seconds < 3600 || seconds <= 0)
        return null;
    const end = Date.UTC(businessNow.getUTCFullYear(), businessNow.getUTCMonth() + 1, 1) - 8 * 3600000, daysLeft = Math.max(0, (end - now.getTime()) / 86400000);
    // Multiple devices run concurrently: average over the longest sampled
    // device duration each day, rather than dividing by summed device time.
    const days = new Map();
    for (const row of recent) {
        const devices = days.get(row.day) || new Map();
        devices.set(row.device, (devices.get(row.device) || 0) + row.sampledSeconds);
        days.set(row.day, devices);
    }
    const observed = Array.from(days.values()).reduce((sum, devices) => sum + Math.max(...devices.values()), 0);
    const projectedMb = total / observed * daysLeft * 86400;
    return { projectedMb, daysLeft, shortfallMb: Math.max(0, projectedMb - available) };
}
function usageCsv(rows) {
    const cell = (value) => { const raw = String(value); return `"${(/^[=+\-@]/.test(raw.trimStart()) ? "'" + raw : raw).replaceAll('"', '""')}"`; };
    return '\uFEFF' + [['日期', '账号', '设备', '采样新增流量（MB）', '连续采样秒数'], ...rows.map(row => [row.day, row.account, row.label, row.usedMb.toFixed(3), row.sampledSeconds])].map(row => row.map(cell).join(',')).join('\r\n');
}
const usageColors = ['#1584e8', '#ef7c25', '#0b9d8a', '#a16add', '#db5376', '#7a9430', '#18a5bf', '#a07554'];
function usageElement(tag, className = '', text = '') {
    const node = document.createElement(tag);
    node.className = className;
    node.textContent = text;
    return node;
}
function usageNativeSelect(label, options, change) {
    const element = usageElement('select');
    element.setAttribute('aria-label', label);
    const control = { element, get value() { return element.value; }, set value(value) { element.value = value; }, setOptions(choices) {
            const value = element.value;
            element.replaceChildren(...choices.map(choice => { const option = usageElement('option', '', choice.text); option.value = choice.value; return option; }));
            element.value = choices.some(choice => choice.value === value) ? value : choices[0]?.value || '';
        } };
    control.setOptions(options);
    element.onchange = () => change(element.value);
    return control;
}
/** Shared DOM renderer: the App supplies its existing menus/motion; LuCI supplies its own controls. */
class UsageChart {
    constructor(root, environment) {
        this.root = root;
        this.environment = environment;
        this.data = { enabled: false, scope: 'local', accounts: [], history: [], series: [] };
        this.options = { scale: 'minute', range: 21600, mode: 'delta', presentation: 'sum', interfaces: null, account: '' };
        this.title = usageElement('h3', '', '流量趋势');
        this.status = usageElement('p', 'traffic-note');
        this.enabled = usageElement('button', 'btn btn-secondary btn-sm', '开启统计');
        this.content = usageElement('div', 'traffic-content');
        this.scopeLocal = usageElement('button', 'btn btn-secondary btn-sm', '仅本机设备');
        this.scopeAll = usageElement('button', 'btn btn-secondary btn-sm', '全部在线设备');
        this.interfaceChoices = usageElement('div', 'traffic-interfaces');
        this.legend = usageElement('div', 'traffic-legend');
        this.plot = usageElement('div', 'traffic-plot');
        this.tooltip = usageElement('div', 'traffic-tooltip');
        this.summary = usageElement('p', 'traffic-note');
        this.devices = usageElement('div', 'traffic-device-list');
        this.canvas = null;
        this.cursor = null;
        this.chart = buildUsageChart([], this.options);
        this.width = 1000;
        this.hover = -1;
        this.busy = false;
        this.accountStamp = '';
        this.interfacesStamp = '';
        this.stamp = '';
        root.classList.add('traffic-chart');
        this.title.textContent = environment.title || '流量趋势';
        this.scopeLocal.textContent = environment.localLabel || '仅本机设备';
        const header = usageElement('div', 'traffic-heading'), intro = usageElement('div');
        intro.append(this.title, this.status);
        this.enabled.type = 'button';
        this.enabled.onclick = () => { void this.configure(!this.data.enabled, this.data.scope); };
        header.append(intro, this.enabled);
        const scope = usageElement('div', 'traffic-scope');
        scope.append(usageElement('span', '', '统计范围'), this.scopeLocal, this.scopeAll);
        this.scopeLocal.type = this.scopeAll.type = 'button';
        this.scopeLocal.onclick = () => { void this.configure(this.data.enabled, 'local'); };
        this.scopeAll.onclick = () => { void this.configure(this.data.enabled, 'all'); };
        const controls = usageElement('div', 'traffic-controls');
        const select = (label, choices, change) => {
            const field = usageElement('div', 'traffic-field'), caption = usageElement('span', '', label);
            const control = (environment.select || usageNativeSelect)(label, choices, change);
            field.append(caption, control.element);
            controls.append(field);
            return control;
        };
        select('统计尺度', usageScales.map(item => ({ value: item.value, text: item.text })), value => {
            this.options.scale = value;
            const scale = usageScales.find(item => item.value === value);
            if (!scale.ranges.includes(this.options.range))
                this.options.range = scale.ranges[scale.ranges.length > 1 ? 1 : 0];
            this.range.setOptions(scale.ranges.map(seconds => ({ value: String(seconds), text: usageRangeLabel(seconds) })));
            this.range.value = String(this.options.range);
            this.draw();
        });
        this.range = select('时间范围', usageScales[0].ranges.map(seconds => ({ value: String(seconds), text: usageRangeLabel(seconds) })), value => { this.options.range = Number(value); this.draw(); });
        this.range.value = String(this.options.range);
        select('流量显示', [{ value: 'delta', text: '每段新增流量' }, { value: 'cumulative', text: '所选范围累计' }], value => { this.options.mode = value; this.draw(); });
        select('曲线', [{ value: 'sum', text: '所有接口合计' }, { value: 'interfaces', text: '按接口同时显示' }], value => {
            this.options.presentation = value;
            this.draw();
        });
        this.account = select('账号', [{ value: '', text: '全部账号' }], value => { this.options.account = value; this.options.interfaces = null; this.draw(); });
        const exportButton = usageElement('button', 'btn btn-secondary btn-sm', '导出 CSV');
        exportButton.type = 'button';
        exportButton.onclick = () => { void this.export().catch(() => { this.status.textContent = '导出失败，请重试。'; }); };
        controls.append(exportButton);
        this.interfaceChoices.hidden = true;
        this.plot.tabIndex = 0;
        this.plot.setAttribute('role', 'group');
        this.plot.setAttribute('aria-label', '流量趋势，使用左右方向键查看采样值');
        this.plot.onpointermove = event => { const bounds = this.plot.getBoundingClientRect(); this.showPoint(Math.round(((event.clientX - bounds.left) / bounds.width * this.width - 68) / (this.width - 86) * (this.chart.times.length - 1))); };
        this.plot.onpointerleave = () => { if (document.activeElement !== this.plot)
            this.hidePoint(); };
        this.plot.onblur = () => this.hidePoint();
        this.plot.onkeydown = event => {
            if (!['ArrowLeft', 'ArrowRight', 'Home', 'End', 'Escape'].includes(event.key))
                return;
            event.preventDefault();
            if (event.key === 'Escape') {
                this.hidePoint();
                return;
            }
            const initial = this.chart.curves.flatMap(curve => curve.points.map((point, index) => point === null ? -1 : index)).filter(index => index >= 0);
            this.showPoint(event.key === 'Home' ? 0 : event.key === 'End' ? this.chart.times.length - 1 : this.hover < 0 ? Math.min(...initial, this.chart.times.length - 1) : this.hover + (event.key === 'ArrowLeft' ? -1 : 1));
        };
        const details = usageElement('details', 'traffic-devices');
        details.append(usageElement('summary', '', '当前在线设备'), this.devices);
        const note = usageElement('p', 'traffic-note', '计费系统每分钟采样 · 空白表示无连续采样 · 累计仅包含所选范围内记录');
        this.content.append(scope, controls, this.interfaceChoices, this.legend, this.plot, this.summary, note, details);
        this.content.hidden = true;
        root.replaceChildren(header, this.content);
        if (typeof ResizeObserver !== 'undefined') {
            this.observer = new ResizeObserver(() => {
                const width = Math.max(300, Math.round(this.plot.clientWidth));
                if (width !== this.width && !this.content.hidden) {
                    this.width = width;
                    this.paint();
                }
            });
            this.observer.observe(this.plot);
        }
        this.update(this.data);
    }
    resize(element, change) { if (this.environment.resize)
        this.environment.resize(element, change);
    else
        change(); }
    async configure(enabled, scope) {
        if (this.busy || (enabled === this.data.enabled && scope === this.data.scope))
            return;
        this.busy = true;
        this.enabled.disabled = this.scopeLocal.disabled = this.scopeAll.disabled = true;
        try {
            await this.environment.configure(enabled, scope);
        }
        catch {
            this.status.textContent = '设置未保存，请重试。';
        }
        finally {
            this.busy = false;
            this.enabled.disabled = this.scopeLocal.disabled = this.scopeAll.disabled = false;
        }
    }
    update(data, message = '') {
        const scoped = normalizeUsageReport(data);
        const next = { ...scoped, enabled: data.enabled === true, scope: data.scope === 'all' ? 'all' : 'local', accounts: scoped.accounts, history: scoped.history, series: scoped.series };
        const stamp = JSON.stringify([next, message]);
        if (stamp === this.stamp)
            return;
        this.stamp = stamp;
        this.data = next;
        this.enabled.textContent = next.enabled ? '暂停统计' : '开启统计';
        this.enabled.setAttribute('aria-pressed', String(next.enabled));
        this.status.textContent = message || (next.enabled ? `计费系统数据 · 每分钟更新 · ${next.scope === 'local' ? this.scopeLocal.textContent : '全部在线设备'}` : '流量统计未开启，可手动开启。');
        this.resize(this.root, () => {
            this.content.hidden = !next.enabled;
            for (const [button, scope] of [[this.scopeLocal, 'local'], [this.scopeAll, 'all']]) {
                button.setAttribute('aria-pressed', String(next.scope === scope));
            }
            if (!next.enabled)
                return;
            const accounts = [...new Set([...next.accounts.map(item => item.account), ...next.series.map(item => item.account)])].sort();
            const accountStamp = JSON.stringify(accounts);
            if (accountStamp !== this.accountStamp) {
                this.accountStamp = accountStamp;
                this.account.setOptions([{ value: '', text: '全部账号' }, ...accounts.map(value => ({ value, text: value }))]);
                this.options.account = this.account.value;
            }
            this.draw(false);
            this.drawDevices();
        });
    }
    showError(message) { this.status.textContent = message; }
    destroy() { this.observer?.disconnect(); }
    updateInterfaces() {
        const choices = usageInterfaces(this.data.series, this.options.account), stamp = JSON.stringify([choices, this.options.interfaces]);
        if (stamp === this.interfacesStamp)
            return;
        this.interfacesStamp = stamp;
        this.interfaceChoices.replaceChildren();
        for (const choice of choices) {
            const label = usageElement('label'), checkbox = usageElement('input');
            checkbox.type = 'checkbox';
            checkbox.value = choice.id;
            checkbox.checked = this.options.interfaces === null || this.options.interfaces.includes(choice.id);
            checkbox.onchange = () => {
                this.options.interfaces = [...this.interfaceChoices.querySelectorAll('input:checked')].map(input => input.value);
                this.draw();
            };
            label.append(checkbox, document.createTextNode(choice.name));
            this.interfaceChoices.append(label);
        }
        if (!choices.length)
            this.interfaceChoices.textContent = '采样后可选择接口';
    }
    draw(animate = true) {
        if (animate) {
            this.resize(this.root, () => this.draw(false));
            return;
        }
        this.interfaceChoices.hidden = this.options.presentation !== 'interfaces';
        this.updateInterfaces();
        this.chart = buildUsageChart(this.data.series, this.options);
        this.width = Math.max(300, this.plot.clientWidth || 1000);
        this.legend.replaceChildren(...this.chart.curves.map((curve, index) => {
            const item = usageElement('span'), dot = usageElement('i');
            dot.style.background = usageColors[index % usageColors.length];
            item.append(dot, document.createTextNode(curve.name));
            return item;
        }));
        this.summary.textContent = this.chart.samples ? `所选范围新增 ${flowLabel(this.chart.totalMb)} · ${this.chart.curves.length} 条曲线` : '所选范围暂无记录，连续两次采样后开始绘图。';
        this.paint();
    }
    paint() {
        const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg'), width = this.width, height = 270, left = 68, right = width - 18, bottom = height - 30, top = 20;
        svg.setAttribute('viewBox', `0 0 ${width} ${height}`);
        svg.setAttribute('aria-hidden', 'true');
        const node = (tag, attrs, text = '') => {
            const item = document.createElementNS(svg.namespaceURI, tag);
            for (const [key, value] of Object.entries(attrs))
                item.setAttribute(key, value);
            item.textContent = text;
            svg.append(item);
            return item;
        };
        const maximum = Math.max(0.01, ...this.chart.curves.flatMap(curve => curve.points.filter((value) => value !== null)));
        const power = 10 ** Math.floor(Math.log10(maximum)), max = Math.ceil(maximum / power / 0.5) * power * 0.5;
        const x = (index) => left + index / Math.max(1, this.chart.times.length - 1) * (right - left), y = (value) => bottom - value / max * (bottom - top);
        for (let i = 0; i <= 4; i++) {
            const value = max * i / 4, position = y(value);
            node('line', { x1: String(left), x2: String(right), y1: String(position), y2: String(position), class: 'traffic-grid' });
            node('text', { x: String(left - 10), y: String(position + 4), 'text-anchor': 'end', class: 'traffic-axis' }, flowLabel(value));
        }
        const labelCount = width < 500 ? 2 : 4;
        for (let i = 0; i < labelCount; i++) {
            const index = Math.round(i * (this.chart.times.length - 1) / (labelCount - 1));
            node('text', { x: String(x(index)), y: String(height - 7), 'text-anchor': i === 0 ? 'start' : i === labelCount - 1 ? 'end' : 'middle', class: 'traffic-axis' }, this.timeLabel(this.chart.times[index]));
        }
        this.chart.curves.forEach((curve, index) => {
            let path = '', connected = false;
            curve.points.forEach((point, i) => {
                if (point === null) {
                    connected = false;
                    return;
                }
                path += `${connected ? 'L' : 'M'}${x(i).toFixed(2)},${y(point).toFixed(2)} `;
                connected = true;
                if (curve.points[i - 1] == null && curve.points[i + 1] == null)
                    node('circle', { cx: String(x(i)), cy: String(y(point)), r: '2.5', fill: usageColors[index % usageColors.length] });
            });
            node('path', { d: path, fill: 'none', stroke: usageColors[index % usageColors.length], 'stroke-width': '1.8', 'stroke-linejoin': 'round', class: 'traffic-line' });
        });
        this.cursor = node('line', { x1: '0', x2: '0', y1: String(top), y2: String(bottom), class: 'traffic-cursor', visibility: 'hidden' });
        this.canvas = svg;
        this.plot.replaceChildren(svg, this.tooltip);
        this.tooltip.hidden = true;
        this.hover = -1;
        if (!this.chart.samples) {
            const empty = usageElement('span', 'traffic-empty', '等待连续采样');
            if (this.options.presentation === 'interfaces' && this.options.interfaces?.length === 0)
                empty.textContent = '请选择至少一个接口';
            this.plot.append(empty);
        }
    }
    timeLabel(at, full = false) {
        const date = new Date((at + 28800) * 1000).toISOString();
        return full ? date.slice(0, 16).replace('T', ' ') : this.options.scale === 'month' ? date.slice(0, 7) : this.options.scale === 'day' || this.options.range > 86400 ? date.slice(5, 10) + (this.options.scale === 'hour' ? ' ' + date.slice(11, 16) : '') : date.slice(11, 16);
    }
    showPoint(index) {
        if (!this.chart.samples || !this.canvas || !this.cursor)
            return;
        this.hover = Math.max(0, Math.min(this.chart.times.length - 1, index));
        const x = 68 + this.hover / Math.max(1, this.chart.times.length - 1) * (this.width - 86);
        this.cursor.setAttribute('x1', String(x));
        this.cursor.setAttribute('x2', String(x));
        this.cursor.setAttribute('visibility', 'visible');
        this.tooltip.replaceChildren(usageElement('strong', '', this.timeLabel(this.chart.times[this.hover], true)));
        this.chart.curves.forEach((curve, i) => {
            const item = usageElement('div'), label = usageElement('span', '', curve.name), value = curve.points[this.hover];
            label.style.color = usageColors[i % usageColors.length];
            item.append(label, document.createTextNode(value === null ? ' —' : ' ' + flowLabel(value)));
            this.tooltip.append(item);
        });
        this.tooltip.hidden = false;
        this.tooltip.style.left = `${Math.max(8, Math.min(this.plot.clientWidth - this.tooltip.offsetWidth - 8, x + 12))}px`;
    }
    hidePoint() { this.hover = -1; this.tooltip.hidden = true; this.cursor?.setAttribute('visibility', 'hidden'); }
    drawDevices() {
        this.resize(this.devices, () => {
            this.devices.replaceChildren();
            for (const account of this.data.accounts) {
                const section = usageElement('section'), title = usageElement('h4', '', account.account);
                section.append(title);
                section.append(usageElement('p', 'traffic-note', account.error || (account.updatedAt ? `更新于 ${new Date(account.updatedAt * 1000).toLocaleTimeString('zh-CN', { hour12: false, timeZone: 'Asia/Shanghai' })}` : '等待查询')));
                for (const device of account.devices) {
                    const row = usageElement('div', 'traffic-device'), identity = usageElement('span', '', device.interfaceName || device.mac || device.ip), value = Number(device.usedFlowMb);
                    identity.append(usageElement('small', '', [device.ip || device.ipv6, device.local ? '本机设备' : '其他设备'].filter(Boolean).join(' · ')));
                    row.append(identity, usageElement('strong', '', device.usedFlowMb !== '' && Number.isFinite(value) ? flowLabel(value) : '--'));
                    section.append(row);
                }
                if (!account.devices.length)
                    section.append(usageElement('p', 'traffic-note', '暂无符合范围的在线设备'));
                const prediction = forecastUsage(this.data.history.filter(row => row.account === account.account), account.remainingFlow || '');
                if (prediction)
                    section.append(usageElement('p', 'traffic-note', `按近 7 天采样估算，月底前约需 ${flowLabel(prediction.projectedMb)}${prediction.shortfallMb > 0 ? `，可能超出余量 ${flowLabel(prediction.shortfallMb)}` : '，当前余量预计足够'}`));
                this.devices.append(section);
            }
            this.devices.append(usageElement('p', 'traffic-note', '分钟明细最多保留 48 小时，小时汇总 90 天，每日汇总 12 个月；设备较多时范围会缩短。'));
            this.devices.append(usageElement('p', 'traffic-note', '以上为本次在线会话已用流量。路由器上游的用量包含经该出口转发的流量。'));
        });
    }
    async export() {
        const csv = usageChartCsv(this.chart, this.options.mode);
        if (this.environment.exportCsv) {
            await this.environment.exportCsv(csv);
            return;
        }
        const link = usageElement('a');
        link.download = 'device-usage.csv';
        link.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
        link.click();
        setTimeout(() => URL.revokeObjectURL(link.href), 1000);
    }
}

return baseclass.extend({flowLabel,flowMb,forecastUsage,usageCsv,buildUsageChart,normalizeUsageReport,usageChartCsv,UsageChart});
