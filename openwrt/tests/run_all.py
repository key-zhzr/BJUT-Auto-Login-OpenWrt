#!/usr/bin/env python3
"""Run all host-side validation available without a live BJUT network or SDK."""

import json
import os
import base64
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
OPENWRT = ROOT / "openwrt"
CORE = OPENWRT / "bjut-autologin"
LUCI = OPENWRT / "luci-app-bjut-autologin"


def run(command, **kwargs):
    print("+", " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True, cwd=ROOT, **kwargs)


def validate_text_files():
    for path in OPENWRT.rglob("*"):
        if not path.is_file() or any(part in ("__pycache__", "node_modules", "test-results", "playwright-report") for part in path.parts):
            continue
        data = path.read_bytes()
        if b"\x00" in data:
            raise RuntimeError(f"unexpected NUL byte: {path}")
        text = data.decode("utf-8")
        for number, line in enumerate(text.splitlines(), 1):
            if line.endswith((" ", "\t")):
                raise RuntimeError(f"trailing whitespace: {path}:{number}")


def validate_json():
    paths = [
        LUCI / "root/usr/share/luci/menu.d/luci-app-bjut-autologin.json",
        LUCI / "root/usr/share/rpcd/acl.d/luci-app-bjut-autologin.json",
    ]
    for path in paths:
        json.loads(path.read_text(encoding="utf-8"))
    acl = json.loads(paths[1].read_text(encoding="utf-8"))
    grants = acl["luci-app-bjut-autologin"]
    for scope in ("read", "write"):
        for permissions in grants.get(scope, {}).get("file", {}).values():
            if any(permission in ("exec", "write") for permission in permissions):
                raise RuntimeError("LuCI ACL unexpectedly grants file execution/write")


def validate_javascript():
    sources = sorted((LUCI / "htdocs/luci-static/resources").rglob("*.js"))
    # LuCI view modules deliberately use a top-level return. Compiling inside
    # Function matches LuCI's loader while still catching JavaScript syntax errors.
    program = "const fs=require('fs'); new Function(fs.readFileSync(process.argv[1], 'utf8'));"
    for source in sources:
        run(["node", "-e", program, source])
    run(["node", OPENWRT / "tests/test_luci_module_contract.cjs"])


def validate_shell():
    paths = [
        CORE / "files/usr/sbin/bjut-autologin",
        CORE / "files/usr/libexec/bjut-billing",
        CORE / "files/usr/libexec/bjut-billing-monitor",
        CORE / "files/usr/libexec/bjut-traffic-monitor",
        CORE / "files/usr/libexec/bjut-traffic-sample",
        CORE / "files/usr/libexec/bjut-maintenance",
        CORE / "files/usr/libexec/rpcd/bjut-autologin",
        *sorted((CORE / "files/usr/lib/bjut-autologin").glob("*.sh")),
        CORE / "files/etc/init.d/bjut-autologin",
        CORE / "files/etc/hotplug.d/iface/95-bjut-autologin",
        *sorted((OPENWRT / "tests/mocks").glob("*.sh")),
    ]
    for path in paths:
        run(["dash", "-n", path])


def validate_c_with_sanitizers():
    source = CORE / "src/bjut-codec.c"
    temp = Path(tempfile.mkdtemp(prefix="bjut-codec-sanitizer-"))
    try:
        binary = temp / "bjut-codec"
        run([
            "cc", "-std=c99", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
            "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
            source, "-o", binary,
        ])
        cases = [
            ("random16", b"", 0),
            ("urlencode", b"a b&%\xf0\x9f\x99\x82", 0),
            ("eportal", "密码🙂".encode(), 0),
            ("base64", b"10.126.21.113", 0),
            ("validate-ipv6", b"2001:db8::10", 0),
            ("validate-ipv6", b"2001:::10", 1),
            ("validate-ipv4", b"192.0.2.1", 0),
            ("validate-ipv4", b"256.0.0.1", 1),
            ("normalize-ip", b"2001:0db8:0000:0000:0000:0000:0000:0001", 0),
            ("normalize-ip", b"192.0.2.1", 0),
            ("normalize-ip", b"2001:::1", 1),
            ("date-days", b"2024-02-29", 0),
            ("date-days", b"2026-02-29", 1),
            ("date-days", b"2026-10-13\nextra", 1),
            ("days-date", b"0", 0),
            ("timestamp-date", b"2214143999000", 0),
            ("timestamp-date", b"7258089600000", 1),
            ("timestamp-date", b"1791820800000x", 1),
            ("eportal", b"\xff", 1),
            ("urlencode", b"x" * 17000, 1),
        ]
        for operation, payload, expected in cases:
            result = subprocess.run(
                [str(binary), operation], input=payload,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                # LeakSanitizer cannot inspect /proc under some container PID
                # namespaces; AddressSanitizer/UBSan checks remain enabled.
                env={"ASAN_OPTIONS": "detect_leaks=0:halt_on_error=1"},
            )
            if (result.returncode == 0) != (expected == 0):
                raise RuntimeError(
                    f"sanitizer codec case failed: {operation}, rc={result.returncode}, "
                    f"stderr={result.stderr.decode(errors='replace')}"
                )
    finally:
        shutil.rmtree(temp)


def validate_html_with_sanitizers():
    temp = Path(tempfile.mkdtemp(prefix="bjut-html-sanitizer-"))
    try:
        binary = temp / 'bjut-html'
        run(['cc','-std=c99','-O1','-g','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',CORE/'src/bjut-html.c','-o',binary])
        cases = [
            ('user-json',b'window.user=function(){})'),
            ('user-json',b'window.user=(function(x){})({"userName":"fixture","brace":"}\\\""});'),
            ('input',b'<input name="checkcode" value="1234">'),
            ('captcha',b'<div id="randomDiv" class="hide"></div>'),
            ('status','<label>状态</label><div><span>正常</span></div>'.encode()),
            ('assets',b'<script src="/Self/static/login.js"></script><link href="/Self/static/login.css">'),
            ('metric','<dt>已用流量</dt><dd><span>2 GB</span></dd>'.encode()),
            ('metric','<dt>已用流量</dt><dt>别的指标</dt><dd>9 GB</dd>'.encode()),
            ('metric','<dl><dt>1536 <small>MB</small></dt><dd>已用流量</dd></dl>'.encode()),
            ('literal',b"const ajaxCsrfToken='safe-token_1';"),
            ('literal',b"ajaxCsrfToken=(()=>evil())"),
            ('object',b'passwordPolicy={"nested":{"escaped":"}\\\""},"FLDMINLENGTH":8}'),
            ('object',b'passwordPolicy={"nested":{}'),
            ('packages',b'<a data-package="2">Package <b>two</b></a>'),
            ('packages',b'<a data-package="2" title="</a>">broken'),
            ('questions',b'<select id="question1"><option value="1">Question</option></select>'),
            ('package-csrf',b"post('doPackage',{csrftoken:'fixture'})"),
            ('package-cancel',b'''<script>$("[data-toggle='undoPackage']")</script>'''),
            ('package-cancel',b"<a data-toggle='undoPackage'>cancel</a>"),
            ('enabled',b"<button id='stopNow' disabled>stop</button>"),
            ('mauth',"<a data-toggle='oprateMauth'>开启</a>".encode()),

        ]
        for operation, payload in cases:
            args=[str(binary),operation] + (['checkcode'] if operation=='input' else ['已用流量'] if operation=='metric' else ['ajaxCsrfToken'] if operation=='literal' else ['passwordPolicy'] if operation=='object' else ['stopNow'] if operation=='enabled' else [])
            result=subprocess.run(args,input=payload,capture_output=True,env={**os.environ,'ASAN_OPTIONS':'detect_leaks=0:halt_on_error=1'})
            if b'Sanitizer' in result.stderr or result.returncode not in (0,1): raise RuntimeError('HTML extraction failed sanitizer check')
    finally: shutil.rmtree(temp)


def validate_security_invariants():
    core_text = (CORE / "files/usr/sbin/bjut-autologin").read_text(encoding="utf-8")
    core_text += (CORE / "files/usr/lib/bjut-autologin/uplinks.sh").read_text(encoding="utf-8")
    if "--interface" not in core_text or "--resolve" not in core_text:
        raise RuntimeError("interface/address pinning was removed")
    if "--pinnedpubkey" not in core_text:
        raise RuntimeError("dormitory SPKI pinning was removed")
    if "url = \"%s\"" not in core_text or "--config -" not in core_text:
        raise RuntimeError("credential URLs are no longer supplied through curl stdin")

    certificate = OPENWRT / "tests/fixtures/dorm-gateway-2024.pem"
    public_pem = subprocess.run(
        ["openssl", "x509", "-in", str(certificate), "-pubkey", "-noout"],
        check=True, stdout=subprocess.PIPE,
    ).stdout
    public_der = subprocess.run(
        ["openssl", "pkey", "-pubin", "-outform", "DER"],
        check=True, input=public_pem, stdout=subprocess.PIPE,
    ).stdout
    expected_pin = "sha256//" + base64.b64encode(hashlib.sha256(public_der).digest()).decode()
    if expected_pin not in core_text:
        raise RuntimeError("embedded dormitory SPKI pin does not match the captured certificate")
    config = (CORE / "files/etc/config/bjut-autologin").read_text(encoding="utf-8")
    if "replace-me" not in config or "option enabled '0'" not in config:
        raise RuntimeError("safe disabled example configuration changed unexpectedly")


def main():
    validate_text_files()
    validate_json()
    validate_javascript()
    validate_shell()
    validate_c_with_sanitizers()
    validate_html_with_sanitizers()
    validate_security_invariants()
    run([sys.executable, "-m", "unittest", "-v", "openwrt/tests/test_openwrt_port.py"])
    run([sys.executable, "openwrt/tests/test_multi_uplink.py"])
    run([sys.executable, "-m", "unittest", "discover", "-s", "openwrt/tests", "-p", "test_router_revision10.py"])
    run([sys.executable, "openwrt/tests/test_pushplus.py"])
    run([sys.executable, "openwrt/tests/test_collaboration.py"])
    run([sys.executable, "openwrt/tests/test_login_order.py"])
    run([sys.executable, "openwrt/tests/test_billing_center.py"])
    run([sys.executable, "openwrt/tests/test_traffic_history.py"])
    run([sys.executable, "openwrt/tests/test_traffic_cadence.py"])
    run([sys.executable, "openwrt/tests/test_package_build.py"])
    print("All OpenWrt port checks passed.")


if __name__ == "__main__":
    main()
