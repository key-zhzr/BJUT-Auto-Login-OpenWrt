#!/usr/bin/env python3
import json
import os
from pathlib import Path
import random
import shutil
import stat
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
OPENWRT = ROOT / "openwrt"
CORE = OPENWRT / "bjut-autologin"
SCRIPT = CORE / "files/usr/sbin/bjut-autologin"
CODEC_SOURCE = CORE / "src/bjut-codec.c"
MOCKS = OPENWRT / "tests/mocks"


class OpenWrtPortTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_dir = Path(tempfile.mkdtemp(prefix="bjut-openwrt-tests-"))
        cls.codec = cls.build_dir / "bjut-codec"
        subprocess.run(
            [
                "cc", "-std=c99", "-O2", "-Wall", "-Wextra", "-Werror",
                str(CODEC_SOURCE), "-o", str(cls.codec),
            ],
            check=True,
        )
        for mock in MOCKS.iterdir():
            mock.chmod(0o755)
        cls.traffic_store = cls.build_dir / 'bjut-traffic-store'
        subprocess.run(['cc','-std=c99','-O2','-Wall','-Wextra','-Werror',str(CORE/'src/bjut-traffic-store.c'),'-o',str(cls.traffic_store),'-lz'],check=True)
        cls.runtime = cls.build_dir / 'bjut-runtime'
        subprocess.run(['cc','-std=c99','-O2','-Wall','-Wextra','-Werror',str(CORE/'src/bjut-runtime.c'),'-o',str(cls.runtime),'-ljson-c'],check=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.build_dir)

    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="bjut-openwrt-case-"))
        self.state = self.temp / "state"
        self.state.mkdir()
        self.sys_net = self.temp / "sys/class/net"
        (self.sys_net / "wlan0/wireless").mkdir(parents=True)
        (self.sys_net / "eth0").mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.temp)

    def codec_run(self, operation, value):
        return subprocess.run(
            [str(self.codec), operation], input=value.encode(),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
        ).stdout.decode()

    def test_random_ticket_needs_no_optional_busybox_applet(self):
        tokens = {self.codec_run('random16', '').strip() for _ in range(64)}
        self.assertEqual(len(tokens), 64)
        for token in tokens:
            self.assertRegex(token, r'^[0-9a-f]{32}$')

    def test_billing_timestamp_dates_use_campus_timezone_beyond_2038(self):
        for value, expected in (
            ('1791820800000', '2026-10-13 00:00:00'),
            ('1791820800', '2026-10-13 00:00:00'),
            ('2214143999000', '2040-02-29 23:59:59'),
            ('7258089599000', '2199-12-31 23:59:59'),
        ):
            self.assertEqual(self.codec_run('timestamp-date', value), expected)
        for invalid in ('2026-10-13', '7258089600000', '9999999999999', '0000000000000', '1791820800000x'):
            result = subprocess.run([str(self.codec), 'timestamp-date'], input=invalid.encode(), capture_output=True)
            self.assertNotEqual(result.returncode, 0, invalid)
            self.assertEqual(result.stdout, b'', invalid)

    @staticmethod
    def python_eportal(value):
        encoded = value.encode("utf-16-be")
        units = [int.from_bytes(encoded[i:i + 2], "big") for i in range(0, len(encoded), 2)]
        return "".join(f"{unit ^ 0x16:02x}" for unit in units)

    def environment(self, scenario="type2_success", **overrides):
        env = os.environ.copy()
        env.update({
            "BJUT_FUNCTIONS_SH": str(MOCKS / "functions.sh"),
            "BJUT_JSHN_SH": str(MOCKS / "jshn.sh"),
            "BJUT_CURL": str(MOCKS / "curl.sh"),
            "BJUT_JSONFILTER": str(MOCKS / "jsonfilter.py"),
            "BJUT_UBUS": str(MOCKS / "ubus.sh"),
            "BJUT_IWINFO": str(MOCKS / "iwinfo.sh"),
            "BJUT_IP": str(MOCKS / "ip.sh"),
            "BJUT_LIB_DIR": str(CORE / "files/usr/lib/bjut-autologin"),
            "BJUT_CODEC": str(self.codec),
            "BJUT_TRAFFIC_STORE": str(self.traffic_store),
            "BJUT_RUNTIME": str(self.codec.parent / 'bjut-runtime'),
            "BJUT_SNAPSHOT_DISABLE": "1",
            "BJUT_LOGGER": str(MOCKS / "logger.sh"),
            "BJUT_SYS_NET": str(self.sys_net),
            "BJUT_STATE_DIR": str(self.state),
            "MOCK_STATE_DIR": str(self.state),
            "MOCK_SCENARIO": scenario,
            "MOCK_POST_LOGIN_DELAY": "0",
        })
        env.update({key: str(value) for key, value in overrides.items()})
        return env

    def run_service(self, command="manual", scenario="type2_success", check=False, **overrides):
        return subprocess.run(
            ["sh", str(SCRIPT), command], env=self.environment(scenario, **overrides),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=check,
        )

    def status(self):
        return json.loads((self.state / "status.json").read_text(encoding="utf-8"))

    def requests(self):
        path = self.state / "requests.log"
        return path.read_text(encoding="utf-8") if path.exists() else ""

    def minimal_tr_path(self):
        tools = self.temp / "minimal-tr"
        tools.mkdir(exist_ok=True)
        executable = tools / "tr"
        # OpenWrt may omit FEATURE_TR_CLASSES. Reject classes instead of letting
        # the host's full tr conceal that incompatibility in portal fixtures.
        executable.write_text(
            '#!/bin/sh\ncase "$*" in *"[:"*) exit 127;; esac\n'
            f'exec "{shutil.which("tr")}" "$@"\n'
        )
        executable.chmod(0o755)
        return str(tools) + os.pathsep + os.environ['PATH']

    def test_codec_matches_original_protocol_vectors(self):
        self.assertEqual(self.codec_run("eportal", "dr1005"), "726427262623")
        self.assertEqual(self.codec_run("eportal", "4.2.2"), "2238243824")
        self.assertEqual(self.codec_run("base64", "10.126.21.113"), "MTAuMTI2LjIxLjExMw==")
        self.assertEqual(self.codec_run("urlencode", "a b&中"), "a%20b%26%E4%B8%AD")
        subprocess.run([str(self.codec), "validate-ipv6"], input=b"2001:db8::10", check=True)
        invalid = subprocess.run(
            [str(self.codec), "validate-ipv6"], input=b"2001:::10",
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertNotEqual(invalid.returncode, 0)

    def test_codec_utf16_and_urlencoding_randomized(self):
        rng = random.Random(20260830)
        alphabet = "abcXYZ019 !&%=中密🙂é"
        from urllib.parse import quote
        for _ in range(40):
            value = "".join(rng.choice(alphabet) for _ in range(rng.randrange(0, 30)))
            self.assertEqual(self.codec_run("eportal", value), self.python_eportal(value))
            self.assertEqual(self.codec_run("urlencode", value), quote(value, safe="-._~"))

    def test_shell_files_have_valid_syntax(self):
        for path in [
            SCRIPT,
            CORE / "files/etc/init.d/bjut-autologin",
            CORE / "files/etc/hotplug.d/iface/95-bjut-autologin",
        ]:
            subprocess.run(["sh", "-n", str(path)], check=True)

    def shell_predicate(self, function, value):
        env = self.environment("online")
        env["BJUT_SOURCE_ONLY"] = "1"
        result = subprocess.run(
            ["sh", "-c", f'. "{SCRIPT}"; {function} "$1"', "test", value],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        return result.returncode == 0

    def test_scan_derived_ssid_rules_remain_specific(self):
        accepted = [
            "bjut-sushe-5G-24vF", "bjut-sushe--2.4G-eXd2", "bjut_sushe-5G-69Xe",
            "bjutsushe-5G-aU97", "bjut-sushe2.4G-a8Gb", "bjut-sushe-2.4-5JqM",
            "bjut_sushe", "CU_bjut-sushe-28Au", "CU_bjut-sushe-28Au_5G",
            "CU_bjut_sushe_8eAs", "CU_-bjut-sushe-Q2Jv", "bjut-suahe-5G-6Y6m",
        ]
        rejected = [
            "room-bjut-sushe-5g", "CU_bjut-sushe-private", "CU_bjut-sushe-28Au-guest",
            "evil-bjut-wifi", "bjut-sushe-private", "bjut-sushe-R8",
            "bjut-sushe-evil-24vF", "bjut_wifi_ceshi",
        ]
        for ssid in accepted:
            self.assertTrue(self.shell_predicate("known_dorm_ssid", ssid), ssid)
        for ssid in rejected:
            self.assertFalse(self.shell_predicate("known_dorm_ssid", ssid), ssid)
        self.assertTrue(self.shell_predicate("known_public_ssid", "BJUT_WIFI"))
        self.assertFalse(self.shell_predicate("known_public_ssid", "bjut_wifi_guest"))

    def test_campus_ipv4_allowlist_is_narrow(self):
        for address in ("10.17.0.1", "10.27.255.254", "10.121.1.2", "10.126.21.3", "10.226.1.2", "172.17.1.2", "172.30.201.42"):
            self.assertTrue(self.shell_predicate("is_campus_ipv4", address), address)
        for address in ("10.16.0.1", "10.28.0.1", "172.31.1.2", "192.168.1.2", "198.18.2.121", "127.0.0.1", "bad"):
            self.assertFalse(self.shell_predicate("is_campus_ipv4", address), address)

    def test_online_path_does_not_probe_or_login(self):
        result = self.run_service(scenario="online")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status()["state"], "online")
        log = self.requests()
        self.assertGreaterEqual(log.count("URL "), 1)
        self.assertLessEqual(log.count("URL "), 3)
        self.assertNotIn("drcom", log)

    def test_current_openwrt_rpcd_iwinfo_path_works_without_cli(self):
        result = self.run_service(
            scenario="online", BJUT_IWINFO="/nonexistent/iwinfo",
            MOCK_UBUS_IWINFO="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status()["ssid"], "bjut_wifi")
        self.assertEqual(self.status()["bssid"], "44:1a:fa:12:34:56")

    def test_type2_login_and_secret_absent_from_process_arguments(self):
        password = "p !&%中"
        result = self.run_service(
            scenario="type2_success", MOCK_ACCOUNT1_PASSWORD=password,
            MOCK_ACCOUNT1_USERNAME="25000001",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        status = self.status()
        self.assertEqual(status["state"], "online")
        self.assertEqual(status["protocol"], "bjut_wifi")
        log = self.requests()
        self.assertIn("DDDDD=25000001", log)
        self.assertIn("upass=p%20%21%26%25%E4%B8%AD", log)
        self.assertIn("IFACE ifhost!wlan0!10.21.2.3", log)
        for line in log.splitlines():
            if line.startswith("ARGS "):
                self.assertNotIn(password, line)
                self.assertNotIn("25000001", line)
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.state / "status.json").stat().st_mode), 0o600)

    @unittest.skipUnless(shutil.which("strace"), "strace is not available")
    def test_execve_trace_contains_no_raw_credentials(self):
        password = "trace-secret-密!"
        trace = self.temp / "execve.trace"
        env = self.environment(
            "type2_success", MOCK_ACCOUNT1_PASSWORD=password,
            MOCK_ACCOUNT1_USERNAME="25123456",
        )
        result = subprocess.run(
            ["strace", "-f", "-s", "512", "-e", "trace=execve", "-o", str(trace),
             "sh", str(SCRIPT), "manual"],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        if result.returncode != 0 and "Operation not permitted" in result.stderr:
            self.skipTest("ptrace is blocked by the test container")
        self.assertEqual(result.returncode, 0, result.stderr)
        traced = trace.read_text(encoding="utf-8", errors="replace")
        self.assertNotIn(password, traced)
        self.assertNotIn("25123456", traced)

    def test_daemon_sleeps_between_checks_instead_of_busy_looping(self):
        process = subprocess.Popen(
            ["sh", str(SCRIPT), "daemon"], env=self.environment("online"),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True,
        )
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and not (self.state / "status.json").exists():
                time.sleep(0.05)
            self.assertTrue((self.state / "status.json").exists())
            first_count = self.requests().count("URL ")
            time.sleep(1)
            self.assertEqual(self.requests().count("URL "), first_count)
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            process.wait(timeout=3)

    def test_definite_rejection_rotates_to_second_account(self):
        result = self.run_service(
            scenario="type2_rotate", MOCK_ACCOUNT_COUNT="2",
            MOCK_ACCOUNT2_USERNAME="25000002",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status()["account"], "25000002")
        self.assertIn("DDDDD=25000001", self.requests())
        self.assertIn("DDDDD=25000002", self.requests())

    def test_type1_expired_certificate_path_requires_spki_pin(self):
        result = self.run_service(
            scenario="type1_pinned", MOCK_SSID="bjut-sushe-5G-24vF",
            MOCK_BSSID="FA:53:29:12:34:56", MOCK_LOGIN_TYPE="type1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status()["protocol"], "bjut-sushe")
        self.assertIn("--pinnedpubkey", self.requests())
        self.assertIn("--resolve wlgn.bjut.edu.cn:802:10.21.221.98", self.requests())

    def test_type1_strict_tls_path_keeps_required_host_and_fields(self):
        result = self.run_service(
            scenario="type1_success", MOCK_SSID="CU_bjut-sushe-28Au",
            MOCK_BSSID="E8:13:6E:69:E0:48", MOCK_LOGIN_TYPE="type1",
            MOCK_ACCOUNT1_USERNAME="25000000", MOCK_ACCOUNT1_PASSWORD="p !",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.requests()
        self.assertIn("user_account=25000000%40campus", log)
        self.assertIn("user_password=p%20%21", log)
        self.assertIn("terminal_type=1", log)
        self.assertIn("--header Host: 10.21.221.98:802", log)

    def test_type3_dual_stack_flow_and_encryption(self):
        result = self.run_service(
            scenario="type3_success", MOCK_DEVICE="eth0",
            MOCK_TRANSPORT_ACTUAL="ethernet", MOCK_LOGIN_TYPE="type3",
            MOCK_IPV4="172.26.33.104", MOCK_ACCOUNT1_USERNAME="25000000",
            MOCK_ACCOUNT1_PASSWORD="safe-fixture-password",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status()["protocol"], "lgn")
        log = self.requests()
        self.assertIn("lgn6.bjut.edu.cn/drcom/getipv6", log)
        self.assertIn("--ipv6", log)
        self.assertIn("--resolve lgn6.bjut.edu.cn:443:[2001:da8:216:30c9::2]", log)
        self.assertIn("wlan_user_ipv6=" + self.python_eportal("2001:da8:216:2633::10"), log)
        self.assertIn("encrypt=1", log)
        self.assertNotIn("safe-fixture-password", log)
        self.assertNotIn("172.26.33.104&", log)
        expected = self.python_eportal(",0,25000000")
        self.assertIn(f"user_account={expected}", log)

    def test_type3_and_ssid_work_without_busybox_character_classes(self):
        path = self.minimal_tr_path()
        env = self.environment('online', PATH=path, BJUT_SOURCE_ONLY='1')
        result = subprocess.run(
            ['sh', '-c', f'. "{SCRIPT}"; known_public_ssid BJUT_WIFI && known_dorm_ssid BJUT_SUSHE'],
            capture_output=True, text=True, env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_service(
            scenario='type3_success', PATH=path, MOCK_DEVICE='eth0',
            MOCK_TRANSPORT_ACTUAL='ethernet', MOCK_LOGIN_TYPE='type3',
            MOCK_IPV4='172.26.33.104', MOCK_ACCOUNT1_USERNAME='25000000',
            MOCK_ACCOUNT1_PASSWORD='safe-fixture-password',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status()['protocol'], 'lgn')
        self.assertIn('encrypt=1', self.requests())

    def test_type3_matches_upstream_sanitized_har_fields(self):
        from urllib.parse import urlsplit, parse_qs
        fixture = json.loads((ROOT / "src-tauri/src/portal_auth/fixtures/lgn-dual-stack.json").read_text())
        result = self.run_service(scenario="type3_success", MOCK_DEVICE="eth0",
                                 MOCK_TRANSPORT_ACTUAL="ethernet", MOCK_LOGIN_TYPE="type3",
                                 MOCK_IPV4="172.26.33.104", MOCK_ACCOUNT1_USERNAME=fixture["user"],
                                 MOCK_ACCOUNT1_PASSWORD=fixture["password"])
        self.assertEqual(result.returncode, 0, result.stderr)
        url = next(line[4:] for line in self.requests().splitlines()
                   if line.startswith("URL ") and "/eportal/portal/login?" in line)
        actual = parse_qs(urlsplit(url).query, keep_blank_values=True)
        expected = parse_qs(urlsplit(fixture["login"]["url"]).query, keep_blank_values=True)
        expected["wlan_user_ip"] = [self.python_eportal("172.26.33.104")]
        expected["wlan_user_ipv6"] = [self.python_eportal("2001:da8:216:2633::10")]
        actual.pop("v"); expected.pop("v")
        self.assertEqual(actual, expected)

    def test_type3_falls_back_to_secondary_fixed_gateway(self):
        result = self.run_service(
            scenario="type3_secondary", MOCK_DEVICE="eth0",
            MOCK_TRANSPORT_ACTUAL="ethernet", MOCK_LOGIN_TYPE="type3",
            MOCK_IPV4="172.26.33.104",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--resolve lgn6.bjut.edu.cn:443:[2001:da8:216:30c9::a]", self.requests())

    def test_type3_verified_ipv4_portal_falls_back_without_ipv6(self):
        result = self.run_service(
            scenario="type3_no_ipv6", MOCK_DEVICE="eth0",
            MOCK_TRANSPORT_ACTUAL="ethernet", MOCK_LOGIN_TYPE="type3",
            MOCK_IPV4="172.26.33.104",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status()["state"], "online")
        self.assertIn("wlan_user_ipv6=&", self.requests())

    def test_type3_ambiguous_submission_is_never_replayed(self):
        self.run_service(scenario="type3_ambiguous", MOCK_DEVICE="eth0",
                         MOCK_TRANSPORT_ACTUAL="ethernet", MOCK_LOGIN_TYPE="type3", MOCK_IPV4="172.26.33.104")
        submissions = [line for line in self.requests().splitlines() if line.startswith("URL ") and "/eportal/portal/login?" in line]
        self.assertEqual(len(submissions), 1)

    def test_type3_foreign_ipv6_is_not_submitted(self):
        result = self.run_service(scenario="type3_foreign_ipv6", MOCK_DEVICE="eth0",
                                 MOCK_TRANSPORT_ACTUAL="ethernet", MOCK_LOGIN_TYPE="type3", MOCK_IPV4="172.26.33.104")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("wlan_user_ipv6=&", self.requests())
        self.assertNotIn(self.python_eportal("2001:db8::10"), self.requests())

    def test_non_campus_source_address_fails_closed_before_http(self):
        result = self.run_service(scenario="type2_success", MOCK_IPV4="192.168.1.2")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.status()["state"], "blocked")
        self.assertEqual(self.requests(), "")

    def test_two_offline_confirmations_are_required_for_normal_checks(self):
        first = self.run_service(command="once", scenario="type2_success")
        self.assertNotEqual(first.returncode, 0)
        self.assertEqual(self.status()["state"], "offline_suspected")
        self.assertNotIn("/drcom/login", self.requests())
        second = self.run_service(command="once", scenario="type2_success")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.status()["state"], "online")

    def test_auth_rejection_sets_cooldown_and_suppresses_retry(self):
        first = self.run_service(command="manual", scenario="auth_rejected")
        self.assertNotEqual(first.returncode, 0)
        status = self.status()
        self.assertEqual(status["state"], "auth_rejected")
        self.assertGreater(status["next_attempt"], status["updated_at"])
        before = self.requests().count("/drcom/login")
        second = self.run_service(command="once", scenario="auth_rejected")
        self.assertNotEqual(second.returncode, 0)
        self.assertEqual(self.status()["state"], "cooldown")
        self.assertEqual(self.requests().count("/drcom/login"), before)

    def test_legacy_http_wifi_requires_explicit_bssid(self):
        result = self.run_service(
            scenario="type2_success", MOCK_COMPATIBILITY="legacy_http",
            MOCK_EXPECTED_BSSID="", MOCK_LOGIN_TYPE="type2",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.status()["state"], "blocked")

    def test_legacy_http_with_exact_bssid_is_explicit_and_functional(self):
        result = self.run_service(
            scenario="type2_success", MOCK_COMPATIBILITY="legacy_http",
            MOCK_EXPECTED_BSSID="44:1a:fa:12:34:56", MOCK_LOGIN_TYPE="type2",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("URL http://10.21.251.3/drcom/login", self.requests())

    def test_legacy_http_bssid_match_cannot_be_disabled_with_strict_mode(self):
        result = self.run_service(
            scenario="type2_success", MOCK_COMPATIBILITY="legacy_http",
            MOCK_STRICT_NETWORK="0", MOCK_EXPECTED_BSSID="44:1a:fa:00:00:01",
            MOCK_LOGIN_TYPE="type2",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.status()["state"], "blocked")
        self.assertNotIn("/drcom/login", self.requests())

    def test_expected_ssid_mismatch_blocks_after_read_only_probe(self):
        result = self.run_service(
            scenario="type2_success", MOCK_EXPECTED_SSID="different-network",
            MOCK_LOGIN_TYPE="type2",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.status()["state"], "blocked")
        self.assertNotIn("/drcom/login", self.requests())

    def test_protocol_transport_mismatch_blocks_credentials(self):
        result = self.run_service(
            scenario="type2_success", MOCK_DEVICE="eth0",
            MOCK_TRANSPORT_ACTUAL="ethernet", MOCK_TRANSPORT="ethernet",
            MOCK_LOGIN_TYPE="type2", MOCK_IPV4="172.26.33.104",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.status()["state"], "blocked")
        self.assertNotIn("/drcom/login", self.requests())

    def test_ambiguous_or_unknown_result_never_rotates_accounts(self):
        for scenario in ("ambiguous", "unknown_result", "oversized"):
            with self.subTest(scenario=scenario):
                shutil.rmtree(self.state)
                self.state.mkdir()
                result = self.run_service(
                    scenario=scenario, MOCK_ACCOUNT_COUNT="2",
                    MOCK_ACCOUNT2_USERNAME="25000002",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.status()["state"], "request_failed")
                self.assertNotIn("DDDDD=25000002", self.requests())

    def test_no_portal_uses_exponential_backoff(self):
        first = self.run_service(command="manual", scenario="no_portal", MOCK_PROBE_DELAY="1")
        self.assertNotEqual(first.returncode, 0)
        status = self.status()
        self.assertEqual(status["state"], "portal_not_found")
        first_delay = status["next_attempt"] - status["updated_at"]
        self.assertEqual(first_delay, 5)
        second = self.run_service(command="manual", scenario="no_portal")
        self.assertNotEqual(second.returncode, 0)
        status = self.status()
        self.assertEqual(status["next_attempt"] - status["updated_at"], 10)

    def test_stale_lock_and_work_directory_are_recovered(self):
        lock = self.state / "lock"
        lock.mkdir()
        (lock / "pid").write_text("99999999\n")
        stale = self.state / "work.99999999"
        stale.mkdir()
        (stale / "response").write_text("fixture")
        result = self.run_service(scenario="online")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(stale.exists())

    def test_active_lock_prevents_overlapping_request(self):
        lock = self.state / "lock"
        lock.mkdir()
        (lock / "pid").write_text(f"{os.getpid()}\n")
        result = self.run_service(scenario="online")
        self.assertEqual(result.returncode, 75)
        self.assertEqual(self.requests(), "")

    def test_disabled_configuration_does_not_require_an_account(self):
        result = self.run_service(
            command="check-config", scenario="online",
            MOCK_ENABLED="0", MOCK_ACCOUNT_COUNT="0",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_enabled_configuration_requires_an_account(self):
        result = self.run_service(
            command="check-config", scenario="online", MOCK_ACCOUNT_COUNT="0",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("At least one enabled account", result.stderr)

    def test_secret_is_absent_from_status_and_syslog(self):
        password = 'never-log-"this"-密'
        result = self.run_service(
            scenario="auth_rejected", MOCK_ACCOUNT1_PASSWORD=password,
            MOCK_ACCOUNT1_USERNAME="25001234",
        )
        self.assertNotEqual(result.returncode, 0)
        status_text = (self.state / "status.json").read_text(encoding="utf-8")
        logger_text = (self.state / "logger.log").read_text(encoding="utf-8")
        self.assertNotIn(password, status_text)
        self.assertNotIn(password, logger_text)
        self.assertIn("25001234", logger_text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
