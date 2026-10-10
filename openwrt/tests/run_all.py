#!/usr/bin/env python3
"""Run all host-side validation available without a live BJUT network or SDK."""

import json
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
        if not path.is_file() or "__pycache__" in path.parts:
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
    source = LUCI / "htdocs/luci-static/resources/view/bjut-autologin/config.js"
    # LuCI view modules deliberately use a top-level return. Compiling inside
    # Function matches LuCI's loader while still catching JavaScript syntax errors.
    program = "const fs=require('fs'); new Function(fs.readFileSync(process.argv[1], 'utf8'));"
    run(["node", "-e", program, source])


def validate_shell():
    paths = [
        CORE / "files/usr/sbin/bjut-autologin",
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
            ("urlencode", b"a b&%\xf0\x9f\x99\x82", 0),
            ("eportal", "密码🙂".encode(), 0),
            ("base64", b"10.126.21.113", 0),
            ("validate-ipv6", b"2001:db8::10", 0),
            ("validate-ipv6", b"2001:::10", 1),
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


def validate_security_invariants():
    core_text = (CORE / "files/usr/sbin/bjut-autologin").read_text(encoding="utf-8")
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
    validate_security_invariants()
    run([sys.executable, "-m", "unittest", "-v", "openwrt/tests/test_openwrt_port.py"])
    run([sys.executable, "openwrt/tests/test_package_build.py"])
    print("All OpenWrt port checks passed.")


if __name__ == "__main__":
    main()
