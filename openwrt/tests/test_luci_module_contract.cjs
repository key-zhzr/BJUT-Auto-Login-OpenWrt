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
