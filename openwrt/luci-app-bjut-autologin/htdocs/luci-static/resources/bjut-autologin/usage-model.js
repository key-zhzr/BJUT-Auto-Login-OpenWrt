'use strict';
'require baseclass';
// Generated from src/device-usage-model.ts.
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

return baseclass.extend({flowLabel,flowMb,forecastUsage,usageCsv});
