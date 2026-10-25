// A LuCI module factory returns a baseclass subclass; the loader imports its
// instance. Bare ES classes pass a syntax check but fail in a real LuCI page.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

class Base {
  static extend(methods) {
    class Module extends this {}
    Object.assign(Module.prototype, methods);
    return Module;
  }
}

const source = fs.readFileSync(path.join(__dirname,
  '../luci-app-bjut-autologin/htdocs/luci-static/resources/bjut-autologin/billing-tools.js'), 'utf8');
const Module = new Function('baseclass', 'bjut', source)(Base, { resize() {} });
assert.ok(Module?.prototype instanceof Base, 'billing-tools must satisfy the LuCI factory contract');
const imported = new Module();
assert.equal(typeof imported.create, 'function');
const root = {}, options = {}, first = imported.create(root, options), second = imported.create({}, {});
assert.equal(first.root, root);
assert.equal(first.options, options);
assert.notEqual(first, second, 'each billing section needs independent state');
assert.equal(typeof first.load, 'function');
assert.equal(typeof first.poll, 'function');
console.log('LuCI billing module factory and independent view instances passed');

const orderSource = fs.readFileSync(path.join(__dirname,
  '../luci-app-bjut-autologin/htdocs/luci-static/resources/bjut-autologin/account-order.js'), 'utf8');
const OrderModule = new Function('baseclass', 'bjut', orderSource)(Base, {});
const order = new OrderModule(), accounts = [{id:'a',user:'25000001'}, {id:'b',user:'25000002'}, {id:'c',user:'25000003'}];
assert.deepEqual(order.arrange(accounts, 'c a').map(item=>item.id), ['c','a','b']);
assert.deepEqual(order.arrange(accounts, ['b','a']).map(item=>item.id), ['b','a','c']);
assert.deepEqual(order.arrange(accounts, 'removed b b').map(item=>item.id), ['b','a','c']);
assert.deepEqual(accounts.map(item=>item.id), ['a','b','c'], 'editing one uplink must not reorder global accounts');
console.log('LuCI per-uplink account order and module factory passed');

const rpcStub = { declare: () => () => Promise.resolve({}), getBaseURL: () => '/ubus', getSessionID: () => '0'.repeat(32) };
for (const viewName of ['overview', 'accounts', 'billing', 'diagnostics', 'logs', 'config']) {
  const viewSource = fs.readFileSync(path.join(__dirname,
    `../luci-app-bjut-autologin/htdocs/luci-static/resources/view/bjut-autologin/${viewName}.js`), 'utf8');
  const ViewClass = new Function(
    'view', 'form', 'uci', 'rpc', 'ui', 'widgets', 'client', 'traffic', 'bjut', 'records', 'BillingTools', 'maintenance', 'accountOrder',
    viewSource
  )(Base, {}, {}, rpcStub, {}, {}, {}, {}, {}, {}, {}, {}, {});
  assert.ok(ViewClass?.prototype instanceof Base, `${viewName}.js must satisfy the LuCI view factory contract`);
  const instance = new ViewClass();
  assert.equal(typeof instance.load, 'function', `${viewName}.js must define load()`);
  assert.equal(typeof instance.render, 'function', `${viewName}.js must define render()`);
}
console.log('All 6 LuCI view modules satisfy factory contract');

const regressionSource = fs.readFileSync(path.join(__dirname, 'luci-regression.js'), 'utf8');
for (const viewName of ['overview', 'accounts', 'billing', 'diagnostics', 'logs', 'config']) {
  assert.ok(regressionSource.includes(`'${viewName}'`), `luci-regression.js must include ${viewName} view`);
  assert.ok(regressionSource.includes(`open('${viewName}')`), `luci-regression.js QA must exercise ${viewName} view`);
}
assert.ok(regressionSource.includes('已受理不等于已送达'), 'luci-regression.js must verify PushPlus accepted != delivered state');
assert.ok(regressionSource.includes('业务码 500'), 'luci-regression.js must verify PushPlus safe failure business code');

// Verify client.watch in-flight guard prevents overlapping refresh backlog
const clientSource = fs.readFileSync(path.join(__dirname,
  '../luci-app-bjut-autologin/htdocs/luci-static/resources/bjut-autologin/client.js'), 'utf8');
let scheduled = [];
const mockWindow = {
  setTimeout: (fn) => { scheduled.push(fn); return scheduled.length; },
  clearTimeout: () => {},
  addEventListener: () => {},
  removeEventListener: () => {},
};
const mockDoc = {
  hidden: false,
  body: {},
  addEventListener: () => {},
  removeEventListener: () => {},
};
class MockMutationObserver { observe() {} disconnect() {} }
const ClientClass = new Function(
  'baseclass', 'rpc', 'request', 'window', 'document', 'MutationObserver', 'performance', '_',
  clientSource
)(Base, rpcStub, {}, mockWindow, mockDoc, MockMutationObserver, { now: () => 0 }, (s) => s);
const client = new ClientClass();
let inFlight = 0, maxInFlight = 0, totalRuns = 0, resolveRefresh;
const handle = client.watch({ isConnected: true }, () => new Promise((resolve) => {
  inFlight++;
  totalRuns++;
  if (inFlight > maxInFlight) maxInFlight = inFlight;
  resolveRefresh = () => { inFlight--; resolve(); };
}), 1);
// Trigger initial scheduled run
const firstTick = scheduled.shift();
firstTick();
// Attempt overlapping refreshes while first is in flight
handle.refresh();
handle.refresh();
assert.equal(inFlight, 1, 'watch() must keep at most one refresh in flight');
assert.equal(maxInFlight, 1, 'overlapping wakeups must not backlog concurrent RPC requests');
resolveRefresh();
handle.stop();
console.log('LuCI client.watch in-flight guard and 6-page regression coverage passed');
