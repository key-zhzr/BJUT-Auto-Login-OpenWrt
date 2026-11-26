'use strict';
'require baseclass';

const labels = {
	online: '互联网已连接',
	account_busy: '账号使用中',
	authenticated_limited: '已认证，探测受限',
	probe_uncertain: '连通性待确认',
	offline_suspected: '正在复核',
	busy: '正在检测',
	waiting_interface: '等待接口',
	cooldown: '等待重试',
	auth_rejected: '账号未通过',
	portal_not_found: '未发现认证网关',
	portal_not_ready: '等待认证网关',
	no_account: '请选择账号',
	stopped: '尚未运行',
	login_accepted: '登录已受理',
	blocked: '请检查上游',
	request_failed: '认证结果待确认',
	logged_out: '已注销',
	logout_failed: '注销待确认'
};
const samples = new Map();

const unifiedCss = `
html{scrollbar-gutter:stable both-edges}
html.bj-host-dark{color-scheme:dark}
.bjut-workbench{
	scrollbar-gutter:stable both-edges;
	--bj-bg:#eef2f8;
	--bj-surface-2:#f6f8fc;
	--bj-card:#ffffff;
	--bj-text:#172033;
	--bj-muted:#64748b;
	--bj-border:#dbe3ee;
	--bj-blue:#2563eb;
	--bj-blue-soft:rgba(37,99,235,.10);
	--bj-action:#2563eb;
	--bj-action-text:#ffffff;
	--bj-ok:#10b981;
	--bj-ok-soft:rgba(16,185,129,.12);
	--bj-warn:#d97706;
	--bj-warn-soft:rgba(217,119,6,.12);
	--bj-error:#ef4444;
	--bj-error-soft:rgba(239,68,68,.12);
	--bj-shadow:0 8px 24px rgba(15,23,42,.05);
	background:none;
	color:var(--bj-text);
	font-size:14px;
	padding:6px 4px 22px
}
html.bj-host-dark .bjut-workbench{
	--bj-bg:#0f172a;
	--bj-surface-2:#162238;
	--bj-card:#1b2840;
	--bj-text:#f1f5f9;
	--bj-muted:#94a3b8;
	--bj-border:#2d3d59;
	--bj-blue:#60a5fa;
	--bj-blue-soft:rgba(96,165,250,.15);
	--bj-action:#60a5fa;
	--bj-action-text:#0b1220;
	--bj-ok:#34d399;
	--bj-ok-soft:rgba(52,211,153,.15);
	--bj-warn:#fbbf24;
	--bj-warn-soft:rgba(251,191,36,.16);
	--bj-error:#f87171;
	--bj-error-soft:rgba(248,113,113,.16);
	--bj-shadow:0 10px 26px rgba(0,0,0,.24);
	color-scheme:dark
}
.bjut-workbench [hidden]{display:none!important}
.bjut-workbench :is(.bj-log,.bj-table-scroll){scrollbar-gutter:stable both-edges}
.bjut-workbench h2{font-size:24px;font-weight:700;line-height:1.25;margin:4px 0 14px}
.bjut-workbench h3{font-size:15.5px;font-weight:650;line-height:1.4;margin:0 0 8px}
.bjut-workbench h4{font-size:14px;font-weight:600;margin:18px 0 10px}
.bjut-workbench p{color:var(--bj-muted);margin:6px 0;line-height:1.55;overflow-wrap:anywhere}
.bjut-workbench .bj-card{border:1px solid var(--bj-border);background:var(--bj-card);border-radius:16px;padding:18px 20px;box-shadow:var(--bj-shadow);min-width:0;margin:14px 0}
.bjut-workbench .bj-card>p{font-size:12.5px;margin:0 0 10px}
.bjut-workbench .bj-header,.bjut-workbench .bj-actions{display:flex;gap:10px;align-items:center;justify-content:space-between;flex-wrap:wrap}
.bjut-workbench .bj-actions{justify-content:flex-start;margin:12px 0 0}
.bjut-workbench .bj-actions>span{font-size:12px;color:var(--bj-muted)}
.bjut-workbench .bj-header h2{margin:0}
.bjut-workbench .bj-badge{display:inline-flex;align-items:center;gap:6px;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:600;background:var(--bj-surface-2);color:var(--bj-muted);border:1px solid var(--bj-border);white-space:nowrap}
.bjut-workbench .bj-badge.ok{background:var(--bj-ok-soft);border-color:transparent;color:var(--bj-ok)}
.bjut-workbench .bj-badge.warn{background:var(--bj-warn-soft);border-color:transparent;color:var(--bj-warn)}
.bjut-workbench .bj-badge.error{background:var(--bj-error-soft);border-color:transparent;color:var(--bj-error)}
.bjut-workbench .bj-badge.info{background:var(--bj-blue-soft);border-color:transparent;color:var(--bj-blue)}
.bjut-workbench .bj-overview-hero{display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap;background:linear-gradient(135deg,var(--bj-card),var(--bj-surface-2))}
.bjut-workbench .bj-overview-hero-main{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
.bjut-workbench .bj-overview-hero-main p{margin:0;font-size:16px;font-weight:700;color:var(--bj-text)}
.bjut-workbench .bj-status-banner{margin:10px 0;padding:10px 14px;border-radius:12px;font-size:13px;background:var(--bj-surface-2);border:1px solid var(--bj-border);color:var(--bj-text)}
.bjut-workbench .bj-status-banner:empty{display:none}
.bjut-workbench .bj-status-banner.is-error{background:var(--bj-error-soft);border-color:rgba(239,68,68,.3);color:var(--bj-error)}
.bjut-workbench .bj-ports{display:grid;grid-template-columns:repeat(auto-fit,minmax(195px,1fr));gap:14px;padding:8px 0 4px}
.bjut-workbench .bj-port{position:relative;border:1px solid var(--bj-border);border-radius:16px;background:var(--bj-card);min-width:0;text-align:center;overflow:hidden;box-shadow:0 4px 14px rgba(15,23,42,.04);transition:border-color .18s ease,box-shadow .18s ease}
.bjut-workbench .bj-port::before{content:"";display:block;height:3px;background:var(--bj-border);transition:background-color .18s ease}
.bjut-workbench .bj-port.is-online::before{background:var(--bj-ok)}
.bjut-workbench .bj-port.is-warn::before{background:var(--bj-warn)}
.bjut-workbench .bj-port.is-error::before{background:var(--bj-error)}
.bjut-workbench .bj-port.is-stale{opacity:.82}
.bjut-workbench .bj-port-title{font-size:16px;font-weight:700;background:var(--bj-surface-2);padding:11px 10px;border-bottom:1px solid var(--bj-border);overflow-wrap:anywhere}
.bjut-workbench .bj-port-body{padding:14px 12px 16px}
.bjut-workbench .bj-port-icon{width:46px;height:46px;margin:0 auto 10px;border-radius:14px;display:grid;place-items:center;background:var(--bj-blue-soft);color:var(--bj-blue)}
.bjut-workbench .bj-port.is-online .bj-port-icon{background:var(--bj-ok-soft);color:var(--bj-ok)}
.bjut-workbench .bj-port.is-error .bj-port-icon{background:var(--bj-error-soft);color:var(--bj-error)}
.bjut-workbench .bj-port.is-warn .bj-port-icon{background:var(--bj-warn-soft);color:var(--bj-warn)}
.bjut-workbench .bj-speed{display:inline-flex;align-items:center;justify-content:center;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:600;background:var(--bj-bg);color:var(--bj-muted)}
.bjut-workbench .bj-paths{display:flex;gap:6px;margin:12px 0 10px}
.bjut-workbench .bj-path{flex:1;padding:5px 6px;border-radius:8px;background:var(--bj-bg);color:var(--bj-muted);font-size:12px;font-weight:600}
.bjut-workbench .bj-path.ok{background:var(--bj-ok-soft);color:var(--bj-ok)}
.bjut-workbench .bj-path.fail{background:var(--bj-error-soft);color:var(--bj-error)}
.bjut-workbench .bj-port-state{font-weight:700;font-size:14.5px;min-height:34px;display:grid;place-items:center}
.bjut-workbench .bj-port-meta{font-size:12px;color:var(--bj-muted);overflow-wrap:anywhere;margin:6px 0 10px;min-height:18px}
.bjut-workbench .bj-traffic{display:grid;gap:5px;font-variant-numeric:tabular-nums;text-align:left;padding:10px;border-radius:10px;background:var(--bj-surface-2);font-size:12.5px}
.bjut-workbench .bj-traffic small{float:right;color:var(--bj-muted);font-weight:500}
.bjut-workbench .bj-select{display:block;width:100%;min-width:0;height:38px;margin:12px 0 8px}
.bjut-workbench .bj-login{width:100%;min-height:38px}
.bjut-workbench .bj-port-actions{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}
.bjut-workbench .bj-port-actions .bj-login{grid-column:1/-1}
.bjut-workbench .bj-port-actions .btn{margin:0;min-width:0;padding:8px 4px}
.bjut-workbench .bj-details{margin-top:10px;text-align:left;font-size:12px;border-top:1px dashed var(--bj-border);padding-top:8px}
.bjut-workbench .bj-details summary{cursor:pointer;color:var(--bj-muted);font-weight:500;padding:4px 0}
.bjut-workbench .bj-account-card{display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap}
.bjut-workbench .bj-account-info{display:flex;align-items:center;gap:12px;min-width:0}
.bjut-workbench .bj-account-rank{display:inline-grid;place-items:center;min-width:30px;height:30px;padding:0 8px;border-radius:10px;background:var(--bj-blue-soft);color:var(--bj-blue);font-size:12px;font-weight:700;font-variant-numeric:tabular-nums}
.bjut-workbench .bj-account-name{font-size:16.5px;font-weight:700;display:block;overflow-wrap:anywhere}
.bjut-workbench .bj-account-meta{display:flex;flex-wrap:wrap;align-items:center;gap:6px;margin-top:4px;font-size:12px;color:var(--bj-muted)}
.bjut-workbench .bj-empty-card{text-align:center;padding:28px 18px;color:var(--bj-muted)}
.bjut-workbench .bj-diag-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,300px),1fr));gap:14px;margin-top:12px}
.bjut-workbench .bj-diag-grid>.bj-card{margin:0}
.bjut-workbench .bj-diag-head{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:10px}
.bjut-workbench .bj-diag-head h3{margin:0}
.bjut-workbench .bj-kv-list{display:grid;gap:6px;padding:10px 12px;border-radius:12px;background:var(--bj-surface-2);font-size:12.5px}
.bjut-workbench .bj-kv-list p{margin:0;color:var(--bj-text);line-height:1.45}
.bjut-workbench .bj-advice-callout{margin:10px 0 6px;padding:9px 12px;border-left:3px solid var(--bj-blue);border-radius:0 10px 10px 0;background:var(--bj-blue-soft);color:var(--bj-text);font-size:12.5px}
.bjut-workbench .bj-diag-card.is-online .bj-advice-callout{border-left-color:var(--bj-ok);background:var(--bj-ok-soft)}
.bjut-workbench .bj-diag-card.is-error .bj-advice-callout{border-left-color:var(--bj-error);background:var(--bj-error-soft)}
.bjut-workbench .bj-diag-time{margin:8px 0 0;font-size:11.5px;color:var(--bj-muted)}
.bjut-workbench .bj-log-toolbar{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin:6px 0 12px}
.bjut-workbench .bj-log-filters{display:flex;align-items:center;gap:8px;flex:1 1 280px;flex-wrap:wrap}
.bjut-workbench .bj-log-filters input{flex:1 1 180px;min-width:140px}
.bjut-workbench .bj-log-filters select{min-width:116px}
.bjut-workbench .bj-log-actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.bjut-workbench .bj-log{white-space:pre-wrap;overflow-wrap:anywhere;max-height:66vh;overflow:auto;font:12px/1.75 ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;padding:16px;border-radius:14px;background:var(--bj-bg);border:1px solid var(--bj-border);margin:0}
.bjut-workbench .bj-summary{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px;margin:16px 0}
.bjut-workbench .bj-summary .bj-card{display:flex;flex-direction:column;justify-content:center;gap:6px;min-height:86px;margin:0;padding:16px 18px}
.bjut-workbench .bj-summary span{font-size:12px;color:var(--bj-muted)}
.bjut-workbench .bj-summary strong{display:block;margin:0;font-size:23px;line-height:1.2;color:var(--bj-blue);font-variant-numeric:tabular-nums}
.bjut-workbench .bj-billing-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,260px),1fr));gap:14px;margin:0 0 16px}
.bjut-workbench .bj-billing-grid>.bj-card{margin:0}
.bjut-workbench progress{width:100%;height:8px;accent-color:var(--bj-blue);border-radius:999px}
.bjut-workbench .bj-package-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,220px),1fr));gap:12px;margin:12px 0}
.bjut-workbench .bj-package-option{display:block;height:auto;min-height:0;min-width:0;line-height:1.5;white-space:normal;text-align:left;border:1px solid var(--bj-border);border-radius:14px;padding:14px;background:var(--bj-surface-2);color:var(--bj-text);cursor:pointer}
.bjut-workbench .bj-package-option.selected{border-color:var(--bj-blue);background:var(--bj-blue-soft)}
.bjut-workbench .bj-package-option p{font-size:12px}
.bjut-workbench .billing-package-badges{display:flex;gap:6px;flex-wrap:wrap}
.bjut-workbench .billing-package-badge{border-radius:12px;background:var(--bj-blue-soft);color:var(--bj-blue);padding:3px 8px;font-size:11px;font-weight:600}
.bjut-workbench .billing-package-badge.next{background:var(--bj-ok-soft);color:var(--bj-ok)}
.bjut-workbench .bj-billing-subtitle{margin:0 0 12px;font-size:12.5px;line-height:1.5;color:var(--bj-muted)}
.bjut-workbench :is(.bj-billing-status,.router-billing-status){font-size:12px;line-height:1.5;color:var(--bj-muted);margin:0 0 10px}
.bjut-workbench .bj-bill-row{display:flex;justify-content:space-between;align-items:baseline;gap:14px;padding:6px 0;font-size:13px;line-height:1.45;border-bottom:1px solid var(--bj-bg)}
.bjut-workbench .bj-bill-row:last-child{border-bottom:0}
.bjut-workbench .bj-bill-row span{color:var(--bj-muted)}
.bjut-workbench .bj-bill-row strong{text-align:right;font-weight:600;overflow-wrap:anywhere;font-variant-numeric:tabular-nums}
.bjut-workbench .btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;min-height:38px;padding:8px 14px;border:1px solid var(--bj-border);border-radius:10px;background:var(--bj-card);color:var(--bj-text);font:inherit;font-size:13px;font-weight:550;line-height:1.2;cursor:pointer;transition:background-color .16s ease,border-color .16s ease,color .16s ease,transform .16s ease}
.bjut-workbench .btn:hover:not(:disabled){background:var(--bj-surface-2);border-color:var(--bj-muted)}
.bjut-workbench .btn:active:not(:disabled){transform:translateY(1px)}
.bjut-workbench .btn:disabled{opacity:.5;cursor:not-allowed}
.bjut-workbench .btn.btn-sm{min-height:32px;padding:6px 12px;font-size:12.5px}
.bjut-workbench .btn.bj-primary{background:var(--bj-action);border-color:var(--bj-action);color:var(--bj-action-text)}
.bjut-workbench .btn.bj-primary:hover:not(:disabled){background:var(--bj-action);border-color:var(--bj-action);filter:brightness(.94)}
.bjut-workbench .btn.bj-danger{color:var(--bj-error);border-color:rgba(239,68,68,.28)}
.bjut-workbench .btn.bj-danger:hover:not(:disabled){background:var(--bj-error-soft);border-color:var(--bj-error)}
.bjut-workbench :is(input:not([type=checkbox]):not([type=radio]),select){min-height:40px;padding:8px 12px;border:1px solid var(--bj-border);border-radius:10px;background:var(--bj-card);color:var(--bj-text);font:inherit;font-size:13px;max-width:100%}
.bjut-workbench :is(input,select):focus-visible,.bjut-workbench .btn:focus-visible{outline:2px solid var(--bj-blue);outline-offset:2px}
.bjut-workbench select{min-width:0;max-width:100%}
.bjut-workbench .bj-record-controls{display:flex;align-items:flex-end;flex-wrap:wrap;gap:12px;margin:14px 0}
.bjut-workbench .bj-record-controls label{flex:1 1 130px;min-width:0;display:grid;gap:6px;color:var(--bj-muted);font-size:12px}
.bjut-workbench .bj-record-controls input,.bjut-workbench .bj-record-controls select{width:100%}
.bjut-workbench .bj-record-controls .btn{min-height:40px}
.bjut-workbench .bj-record-controls.bj-billing-controls{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr) auto;gap:12px}
.bjut-workbench .bj-record-controls.bj-billing-controls label{display:grid;flex:none;min-width:0}
.bjut-workbench .bj-billing-controls label>span{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
.bjut-workbench .bj-record-range{display:flex;align-items:flex-end;gap:8px;flex:2 1 300px;min-width:0}
.bjut-workbench .bj-record-range>label{flex:1 1 0;min-width:0}
.bjut-workbench .bj-range-sep{padding-bottom:11px;color:var(--bj-muted);font-size:12px}
.bjut-workbench .bj-tabs{display:inline-flex;gap:6px;flex-wrap:wrap;margin:14px 0;padding:4px;border-radius:13px;background:var(--bj-bg);border:1px solid var(--bj-border)}
.bjut-workbench .bj-tabs .btn{background:transparent;border-color:transparent;min-height:36px;padding:7px 14px;font-size:13.5px;border-radius:9px}
.bjut-workbench .bj-tabs .btn:hover:not(:disabled){background:var(--bj-card);border-color:transparent}
.bjut-workbench .bj-tabs .active{background:var(--bj-card);border-color:var(--bj-border);color:var(--bj-blue);font-weight:650;box-shadow:0 2px 6px rgba(15,23,42,.06)}
.bjut-workbench .bj-table-scroll{overflow:auto;margin:12px 0;border:0;border-radius:10px;scrollbar-gutter:auto}
.bjut-workbench .bj-table{width:100%;min-width:100%;border-collapse:collapse;font-size:12.5px}
.bjut-workbench .bj-table th{padding:10px;text-align:left;white-space:nowrap;font-size:12px;font-weight:650;color:var(--bj-text);background:var(--bj-surface-2);border-bottom:1px solid var(--bj-border)}
.bjut-workbench .bj-table td{padding:10px;text-align:left;white-space:nowrap;border-bottom:1px solid var(--bj-border)}
.bjut-workbench .bj-table tbody tr:last-child td{border-bottom:0}
.bjut-workbench .bj-card details{margin:12px 0 0;padding-top:0}
.bjut-workbench .bj-card details>summary{font-size:13px;font-weight:550;color:var(--bj-text);padding:6px 0;cursor:pointer}
.bjut-workbench .bj-form{display:grid;gap:12px;padding:12px 0 4px}
.bjut-workbench .bj-form label{display:grid;gap:6px;font-size:12px;color:var(--bj-muted)}
.bjut-workbench .bj-form input,.bjut-workbench .bj-form select{width:100%;min-width:0}
.bjut-workbench .bj-editor{display:grid;gap:14px}
.bjut-workbench .bj-editor label{display:grid;gap:6px;font-size:12.5px;color:var(--bj-muted)}
.bjut-workbench .bj-editor label:has(input[type=checkbox]){display:flex;align-items:center;gap:8px;color:var(--bj-text);font-size:13.5px}
.bjut-workbench .bj-device{margin-top:12px}
.bjut-workbench .bj-card img{display:block;max-width:100%;margin:12px 0;border-radius:10px}
.bj-account-order{display:grid;gap:8px;max-width:100%}
.bj-account-order-row{display:grid;grid-template-columns:auto minmax(0,1fr) auto auto;gap:8px;align-items:center;padding:7px 10px;border:1px solid var(--bj-border);border-radius:10px;background:var(--bj-surface-2)}
.bj-account-order-rank{font-size:11.5px;font-weight:700;color:var(--bj-blue);min-width:22px;font-variant-numeric:tabular-nums}
.bj-account-order-row label{display:flex;align-items:center;gap:8px;min-width:0;overflow-wrap:anywhere;margin:0}
.bj-account-order-row .btn{min-height:30px;padding:4px 10px}
.bj-account-order-row .btn:not(:disabled){color:inherit}
.bj-pushplus-status{padding:12px 14px;border-radius:12px;border:1px solid var(--bj-border);background:var(--bj-surface-2)}
.bj-pushplus-status[data-state="queued"]{border-color:var(--bj-blue);background:var(--bj-blue-soft)}
.bj-pushplus-status[data-state="accepted"]{border-color:var(--bj-ok);background:var(--bj-ok-soft)}
.bj-pushplus-status[data-state="error"]{border-color:var(--bj-error);background:var(--bj-error-soft)}
.bj-pushplus-detail{margin:6px 0 0;font-size:12.5px}
.bjut-workbench .bj-record-panel{margin:0;padding:20px}
.bjut-workbench .bj-record-panel .bj-record-heading{display:flex;align-items:flex-start;justify-content:space-between;gap:12px;flex-wrap:wrap}
.bjut-workbench .bj-record-panel .bj-record-heading h3{margin:0}
.bjut-workbench .bj-record-panel .bj-record-heading p{margin:4px 0 0;font-size:12px;color:var(--bj-muted)}
.bjut-workbench .bj-section-heading{margin:22px 0 12px}
.bjut-workbench .bj-record-message{overflow-wrap:anywhere}
.bjut-workbench .bj-record-results{display:grid;gap:12px;margin:4px 0 0}
.bjut-workbench .bj-record-card{margin:0;padding:14px;border:1px solid var(--bj-border);border-radius:14px;background:var(--bj-surface-2);min-width:0}
.bjut-workbench .bj-record-card h3{font-size:14px;margin:0 0 4px}
.bjut-workbench .bj-record-card>p{font-size:12px;margin:0 0 8px}
.bjut-workbench .bj-record-card .bj-table-scroll{background:none}
.bjut-workbench .bj-record-card .bj-actions{margin-top:10px}
.bjut-workbench .bj-record-card .btn{min-height:32px;padding:6px 12px;font-size:12.5px}
.bjut-workbench .bj-record-footer{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-top:10px}
.bjut-workbench .bj-record-pager{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.bjut-workbench .bj-record-card .bj-actions>span{font-size:12px}
.bj-enter{animation:bjEnter .22s cubic-bezier(.22,1,.36,1)}
@keyframes bjEnter{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:translateY(0)}}
@media(prefers-reduced-motion:reduce){.bj-enter{animation:none}}
@media(max-width:900px){.bjut-workbench .bj-summary{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media(max-width:600px){
	html{scrollbar-width:thin}
	html::-webkit-scrollbar,.bjut-workbench :not(.bj-log)::-webkit-scrollbar{width:3px;height:3px}
	.bjut-workbench .bj-log::-webkit-scrollbar{width:8px;height:8px}
	.bjut-workbench .bj-ports{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}
	.bjut-workbench .bj-card{padding:15px}
	.bjut-workbench .bj-port-body{padding:12px 8px 14px}
	.bjut-workbench .bj-port-title{font-size:14.5px;padding:10px 6px}
	.bjut-workbench .bj-port-actions .btn{font-size:12px;white-space:nowrap}
	.bjut-workbench .bj-billing-grid{grid-template-columns:1fr}
	.bjut-workbench .bj-record-controls.bj-billing-controls{grid-template-columns:1fr}
	.bjut-workbench .bj-tabs{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:6px}
	.bjut-workbench .bj-tabs .btn{width:100%;padding-inline:8px}
	.bjut-workbench .bj-record-controls>.btn{width:100%}
	.bjut-workbench .bj-record-range{flex:1 1 100%}
	.bjut-workbench .bj-summary{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}
	.bjut-workbench .bj-summary .bj-card{min-height:76px;padding:13px}
	.bjut-workbench .bj-summary strong{font-size:19.5px}
	.bjut-workbench .bj-record-panel{padding:15px}
	.bjut-workbench .bj-record-card{padding:12px}
}
`;

function darkHost() {
	try {
		const parse = value => {
			const match = String(value).match(/rgba?\(([^)]+)\)/);
			if (!match) return null;
			const parts = match[1].split(/[\s,/]+/).map(Number);
			return { r: parts[0] || 0, g: parts[1] || 0, b: parts[2] || 0, a: parts[3] === undefined ? 1 : parts[3] };
		};
		let color = parse(getComputedStyle(document.body).backgroundColor);
		if (!color || color.a < .1) color = parse(getComputedStyle(document.documentElement).backgroundColor);
		if (color && color.a >= .1) return (0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b) / 255 < .5;
		const markers = [document.documentElement.className, document.body.className,
			document.documentElement.dataset.theme || '', document.documentElement.dataset.bsTheme || '',
			document.documentElement.dataset.darkmode || ''].join(' ').toLowerCase();
		return /(^|[\s-])dark([\s-]|$)/.test(markers) || markers.includes('darkmode');
	} catch (error) {
		return false;
	}
}

let themeObserverAttached = false;
function syncHostTheme() {
	document.documentElement.classList.toggle('bj-host-dark', darkHost());
	if (themeObserverAttached || typeof MutationObserver === 'undefined') return;
	themeObserverAttached = true;
	const observer = new MutationObserver(function(records) {
		if (records.every(function(record) { return record.target === document.documentElement && record.attributeName === 'class'; })) {
			const isDark = darkHost();
			if (document.documentElement.classList.contains('bj-host-dark') === isDark) return;
		}
		document.documentElement.classList.toggle('bj-host-dark', darkHost());
	});
	const opts = { attributes: true, attributeFilter: ['class', 'data-theme', 'data-bs-theme', 'data-darkmode'] };
	observer.observe(document.documentElement, opts);
	if (document.body) observer.observe(document.body, opts);
}

function portIcon() {
	const parser = new DOMParser();
	return document.importNode(parser.parseFromString('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="26" height="26" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4 3h16v13h-5v5H9v-5H4z"/><path d="M8 7v4m3-4v4m3-4v4m3-4v4M12 16v5"/></svg>', 'image/svg+xml').documentElement, true);
}

function bytes(value) {
	let n = Number(value) || 0, unit = 0;
	const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
	while (n >= 1024 && unit < 4) { n /= 1024; unit++; }
	return n.toFixed(unit > 1 ? 1 : 0) + ' ' + units[unit];
}
function rate(port) {
	const now = performance.now(), previous = samples.get(port.uplink);
	samples.set(port.uplink, { at: now, tx: Number(port.txBytes), rx: Number(port.rxBytes) });
	const seconds = previous ? (now - previous.at) / 1000 : 0;
	return seconds > .2 ? { tx: Math.max(0, Number(port.txBytes) - previous.tx) / seconds, rx: Math.max(0, Number(port.rxBytes) - previous.rx) / seconds } : { tx: 0, rx: 0 };
}

function portToneClass(item) {
	if (item.stale) return 'is-stale';
	if (item.state === 'online') return 'is-online';
	if (['auth_rejected', 'portal_not_found', 'blocked', 'logout_failed'].includes(item.state)) return 'is-error';
	if (['authenticated_limited', 'probe_uncertain', 'offline_suspected', 'cooldown', 'account_busy', 'logged_out', 'waiting_interface', 'portal_not_ready', 'no_account'].includes(item.state)) return 'is-warn';
	return '';
}

function portGrid(actions) {
	const root = E('div', { 'class': 'bj-ports' }), entries = new Map();
	function text(entry, key, value) { if (entry.fields[key].textContent !== value) entry.fields[key].textContent = value; }
	function create(item) {
		const fields = {}, slot = function(key, tag, cls) { return fields[key] = E(tag || 'span', { 'class': cls || '' }); };
		const selector = E('select', { 'class': 'cbi-input-select bj-select', 'aria-label': _('账号') });
		const note = slot('note', 'p', 'bj-port-meta'); note.setAttribute('role', 'status');
		const entry = { fields: fields, selector: selector, accounts: '', pending: null, item: item };
		async function act(kind, button) {
			if (kind === 'switchAccount' && !selector.value) { note.textContent = _('请先选择要切换的账号'); return; }
			button.disabled = true;
			try {
				const response = await actions[kind](item.id, selector.value);
				entry.pending = { at: Date.now(), updated: entry.item.updated_at, message: response.message || _('操作已开始') };
				note.textContent = entry.pending.message;
				if (actions.changed) void actions.changed();
			} catch (error) {
				note.textContent = String(error.message || error);
			} finally {
				button.disabled = false;
			}
		}
		const login = E('button', { 'class': 'btn bj-primary bj-login', type: 'button', click: function() { void act('login', login); } }, _('登录'));
		const change = E('button', { 'class': 'btn', type: 'button', click: function() { void act('switchAccount', change); } }, _('切换账号'));
		const logout = E('button', { 'class': 'btn', type: 'button', click: function() { void act('logout', logout); } }, _('注销'));
		const details = E('details', { 'class': 'bj-details' }, [E('summary', {}, _('网络详情')), slot('network', 'p'), slot('address4', 'p'), slot('address6', 'p'), slot('message', 'p')]);
		entry.element = E('article', { 'class': 'bj-port bj-enter' }, [
			slot('title', 'div', 'bj-port-title'),
			E('div', { 'class': 'bj-port-body' }, [
				E('div', { 'class': 'bj-port-icon', 'aria-hidden': 'true' }, portIcon()),
				slot('speed', 'div', 'bj-speed'),
				E('div', { 'class': 'bj-paths' }, [slot('ipv4', 'span', 'bj-path'), slot('ipv6', 'span', 'bj-path')]),
				slot('state', 'div', 'bj-port-state'),
				note,
				E('div', { 'class': 'bj-traffic' }, [E('div', {}, [slot('tx'), slot('txRate', 'small')]), E('div', {}, [slot('rx'), slot('rxRate', 'small')])]),
				selector,
				E('div', { 'class': 'bj-port-actions' }, [login, actions.switchAccount ? change : null, actions.logout ? logout : null]),
				details
			])
		]);
		root.append(entry.element);
		return entry;
	}
	function update(data, portData, accountData) {
		const ids = new Set((data.uplinks || []).map(function(item) { return item.id; }));
		entries.forEach(function(entry, id) { if (!ids.has(id)) { entry.element.remove(); entries.delete(id); samples.delete(id); } });
		(data.uplinks || []).forEach(function(item) {
			let entry = entries.get(item.id);
			if (!entry) { entry = create(item); entries.set(item.id, entry); }
			entry.item = item;
			entry.element.className = ['bj-port', portToneClass(item)].filter(Boolean).join(' ');
			const accounts = (accountData.accounts || []).filter(function(account) { return account.hasPassword; }), stamp = JSON.stringify(accounts);
			if (stamp !== entry.accounts) {
				const selected = entry.selector.value;
				entry.selector.replaceChildren(E('option', { value: '' }, _('自动选择账号')));
				accounts.forEach(function(account) { entry.selector.append(E('option', { value: account.id }, account.user + (account.enabled ? '' : _('（手动）')))); });
				if (accounts.some(function(account) { return account.id === selected; })) entry.selector.value = selected;
				entry.accounts = stamp;
			}
			const port = (portData.ports || []).find(function(port) { return port.uplink === item.id; }) || {}, speed = Number(port.speedMbps), rates = rate(Object.assign({ uplink: item.id }, port));
			text(entry, 'title', item.device || port.device || item.network || item.id);
			text(entry, 'speed', port.linkUp === 0 ? _('已断开') : speed ? (speed >= 1000 ? (speed / 1000) + ' GbE' : speed + ' Mbps') : item.transport === 'wifi' ? 'Wi-Fi' : _('有线'));
			[['ipv4', item.internet4], ['ipv6', item.internet6]].forEach(function(pair) {
				text(entry, pair[0], (item.stale ? '上次 ' : '') + (pair[1] === 'reachable' ? '✓ ' : pair[1] === 'unreachable' ? '× ' : '— ') + (pair[0] === 'ipv4' ? 'IPv4' : 'IPv6'));
				entry.fields[pair[0]].className = 'bj-path ' + (item.stale ? '' : pair[1] === 'reachable' ? 'ok' : pair[1] === 'unreachable' ? 'fail' : '');
			});
			text(entry, 'state', _(item.stale ? '数据已过期' : labels[item.state] || item.state || '等待检测'));
			const pending = entry.pending && Date.now() - entry.pending.at < 15000 && entry.pending.updated === item.updated_at;
			const phase = item.checking ? item.check_message || _('正在检测…') : item.operation && ['queued', 'running'].includes(item.operation.state) ? item.operation.phase || _('正在处理…') : pending ? entry.pending.message : item.message || '';
			text(entry, 'note', [item.account ? _('账号') + ' ' + item.account : '', phase || (!item.account ? item.message || _('暂无认证账号') : '')].filter(Boolean).join(' · '));
			text(entry, 'tx', '▲ ' + bytes(port.txBytes));
			text(entry, 'rx', '▼ ' + bytes(port.rxBytes));
			text(entry, 'txRate', bytes(rates.tx) + '/s');
			text(entry, 'rxRate', bytes(rates.rx) + '/s');
			text(entry, 'network', [item.network, item.network6].filter(Boolean).join(' / '));
			text(entry, 'address4', 'IPv4 ' + (item.ipv4 || '--'));
			text(entry, 'address6', 'IPv6 ' + (item.ipv6 || '--'));
			text(entry, 'message', _('认证会话') + '：' + (item.session === 'online' ? _('已认证') : item.session === 'offline' ? _('未认证') : _('待确认')) + '\n' + (item.message || '') + (item.updated_at ? '\n' + new Date(item.updated_at * 1000).toLocaleString() : ''));
		});
	}
	return { element: root, render: function(data, portData, accountData) { resize(root, function() { update(data, portData, accountData); }); } };
}

const motion = new WeakMap();
function resize(element, update, finished) {
	const height = element.getBoundingClientRect().height, old = motion.get(element);
	if (old) { old.animation.cancel(); old.restore(); motion.delete(element); }
	update();
	const target = element.getBoundingClientRect().height;
	if (Math.abs(height - target) < 1 || !element.animate || window.matchMedia('(prefers-reduced-motion: reduce)').matches) { if (finished) finished(); return; }
	const overflow = element.style.overflow, sizing = element.style.boxSizing;
	const restore = function() { element.style.overflow = overflow; element.style.boxSizing = sizing; };
	element.style.overflow = 'clip';
	element.style.boxSizing = 'border-box';
	const animation = element.animate([{ height: height + 'px' }, { height: target + 'px' }], { duration: target > height ? 220 : 180, easing: 'cubic-bezier(.2,.7,.3,1)', fill: 'both' });
	motion.set(element, { animation: animation, restore: restore });
	animation.onfinish = function() { if (motion.get(element)?.animation !== animation) return; if (finished) finished(); animation.cancel(); restore(); motion.delete(element); };
}

const disclosureRoots = new WeakSet();
function disclosures(root) {
	if (disclosureRoots.has(root)) return root;
	disclosureRoots.add(root);
	const intended = new WeakMap();
	root.addEventListener('click', function(event) {
		const summary = event.target.closest('summary'), details = summary?.parentElement;
		if (!summary || !root.contains(summary) || details.tagName !== 'DETAILS' || event.target.closest('button,a,input,select')) return;
		event.preventDefault();
		const expanded = !(intended.has(details) ? intended.get(details) : details.open);
		intended.set(details, expanded);
		if (expanded) {
			resize(details, function() { details.open = true; });
		} else {
			const before = details.getBoundingClientRect().height;
			details.open = false;
			const closed = details.getBoundingClientRect().height;
			details.open = true;
			// Animate the real details box; a collapse keeps descendants mounted.
			const old = motion.get(details);
			if (old) { old.animation.cancel(); old.restore(); motion.delete(details); }
			if (!details.animate || window.matchMedia('(prefers-reduced-motion: reduce)').matches) { details.open = false; return; }
			const overflow = details.style.overflow;
			details.style.overflow = 'clip';
			const animation = details.animate([{ height: before + 'px' }, { height: closed + 'px' }], { duration: 180, easing: 'cubic-bezier(.2,.7,.3,1)', fill: 'both' });
			const restore = function() { details.style.overflow = overflow; };
			motion.set(details, { animation: animation, restore: restore });
			animation.onfinish = function() { if (motion.get(details)?.animation !== animation) return; details.open = !!intended.get(details); animation.cancel(); restore(); motion.delete(details); };
		}
	});
	return root;
}

async function copyText(value) {
	if (navigator.clipboard?.writeText) {
		await navigator.clipboard.writeText(value);
		return;
	}
	const area = E('textarea', { readonly: true, style: 'position:fixed;opacity:0' });
	area.value = value;
	const previousFocus = document.activeElement;
	document.body.append(area);
	try {
		area.select();
		if (!document.execCommand('copy')) throw new Error(_('浏览器拒绝访问剪贴板'));
	} finally {
		area.remove();
		previousFocus?.focus();
	}
}

return baseclass.extend({
	copyText: copyText,
	resize: resize,
	disclosures: disclosures,
	style: function() {
		syncHostTheme();
		return E('style', {}, unifiedCss);
	},
	label: function(state) { return _(labels[state] || state || '等待检测'); },
	bytes: bytes,
	portGrid: portGrid,
	ports: function(data, portData, accountData, login) {
		const grid = portGrid({ login: login });
		grid.render(data, portData, accountData);
		return grid.element;
	}
});
