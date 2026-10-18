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
