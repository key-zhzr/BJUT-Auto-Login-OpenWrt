#!/usr/bin/env python3
"""Regression tests for bounded probes and low-cost read-only RPCs."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import unittest
import test_multi_uplink as multi
import test_openwrt_port as base


class RuntimeTests(unittest.TestCase):
    setUpClass = classmethod(multi.MultiUplinkTests.setUpClass.__func__)
    tearDownClass = classmethod(multi.MultiUplinkTests.tearDownClass.__func__)
    setUp = base.OpenWrtPortTests.setUp
    tearDown = base.OpenWrtPortTests.tearDown
    environment = base.OpenWrtPortTests.environment
    run_service = base.OpenWrtPortTests.run_service
    config = multi.MultiUplinkTests.config
    rpc = multi.MultiUplinkTests.rpc

    def fixture(self):
        env = self.config()
        env.update(BJUT_SNAPSHOT_DISABLE='0', BJUT_CONFIG_FILE=env['MOCK_CONFIG_JSON'],
                   BJUT_CONFIG_DELTA=str(self.temp / 'delta'))
        config = json.loads(Path(env['MOCK_CONFIG_JSON']).read_text())
        config['main'].update(traffic_monitor='1', traffic_scope='local')
        Path(env['MOCK_CONFIG_JSON']).write_text(json.dumps(config))
        for section, device, user in [('dorm_a', 'lan3', '25000001'), ('dorm_b', 'lan4', '25000002')]:
            (self.state / f'uplink-{section}.json').write_text(json.dumps({
                'id': section, 'device': device, 'state': 'online', 'account': user,
                'session': 'online', 'updated_at': int(time.time()), 'internet4': 'reachable'}))
            (self.sys_net / device / 'statistics').mkdir()
            for file, value in [('carrier', '1'), ('speed', '1000'), ('statistics/rx_bytes', '123456'), ('statistics/tx_bytes', '98765')]:
                (self.sys_net / device / file).write_text(value + '\n')
        (self.state / 'traffic').mkdir()
        (self.state / 'billing-latest').mkdir()
        self.keys = {}
        for i in (1, 2):
            user = f'2500000{i}'
            key = hashlib.sha256(user.encode()).hexdigest()
            self.keys[user] = key
            (self.state / f'traffic/{key}-at').write_text('1793100000')
            (self.state / f'traffic/{key}-meta.json').write_text(json.dumps({'remainingFlow': '123.456', 'balance': '8.1234'}))
            (self.state / f'traffic/{key}-devices-local.json').write_text(json.dumps([{'ip': f'10.126.{i}.1', 'usedFlowMb': '9.125', 'local': True}]))
            (self.state / f'billing-latest/{key}.json').write_text(json.dumps({'account': user, 'state': 'ready', 'balance': '8.1234'}))
        (self.state / 'usage-samples.tsv').write_text(f'2026-10-27\t{self.keys["25000001"]}\tabcd\taa:bb:cc:dd:ee:ff\t1.234\t60\t1\n')
        (self.state / 'usage-curves.tsv').write_text(f'60\t1793100000\t{self.keys["25000001"][:16]}\tabcd\tinterface:lan3\tlan3\t1\t1.234\t60\t1793099941\t1793100001\n')
        (self.state / 'traffic-switches.tsv').write_text('1793100001\tinterface:lan3\tlan3\t25000002\t25000001\t流量耗尽后换号\n')
        return env

    def response(self, method, env, payload=None, **overrides):
        result = self.rpc(method, payload or {}, **{**env, **overrides})
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    @staticmethod
    def stable(value):
        if isinstance(value, dict):
            return {k: RuntimeTests.stable(v) for k, v in value.items() if k not in ('generated_at', 'age_seconds')}
        if isinstance(value, list):
            return [RuntimeTests.stable(v) for v in value]
        return value

    def test_native_views_match_the_shell_contract_without_config_parsing_when_warm(self):
        env = self.fixture()
        for method in ('dashboard', 'status', 'ports', 'accounts', 'billing_cached', 'traffic'):
            with self.subTest(method=method):
                legacy = self.response(method, env, BJUT_SNAPSHOT_DISABLE='1')
                native = self.response(method, env)
                self.assertEqual(self.stable(native), self.stable(legacy))
                warm = self.response(method, env, BJUT_FUNCTIONS_SH='/missing-library')
                self.assertEqual(self.stable(native), self.stable(warm))
        context = (self.state / 'view-context.json').read_text()
        self.assertNotIn('fixture password', context)
        self.assertEqual((self.state / 'view-context.json').stat().st_mode & 0o777, 0o600)
        self.assertNotIn('signature', json.dumps(native))

    def test_same_second_configuration_and_pending_delta_edits_invalidate_the_cache(self):
        env = self.fixture()
        first = self.response('accounts', env)
        cfg = Path(env['MOCK_CONFIG_JSON'])
        stat = cfg.stat()
        original = cfg.read_text()
        cfg.write_text(original.replace('25000001', '25000003'))
        os.utime(cfg, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        second = self.response('accounts', env)
        self.assertNotEqual(first['accounts'][0]['user'], second['accounts'][0]['user'])
        old = json.loads((self.state / 'view-context.json').read_text())['fingerprint']
        Path(env['BJUT_CONFIG_DELTA']).write_text('pending change')
        self.response('accounts', env)
        self.assertNotEqual(old, json.loads((self.state / 'view-context.json').read_text())['fingerprint'])

    def test_live_status_operation_and_port_metrics_are_never_hidden_by_the_context_cache(self):
        env = self.fixture()
        self.response('dashboard', env)
        (self.sys_net / 'lan3/statistics/rx_bytes').write_text('999999')
        (self.state / 'phase-dorm_a').write_text(f'{os.getpid()} {int(time.time())}\n正在确认网关\n')
        (self.state / 'operation-dorm_a.json').write_text(json.dumps({'id': 'a'*32, 'state': 'running', 'deadline': int(time.time())-1}))
        result = self.response('dashboard', env, BJUT_FUNCTIONS_SH='/missing-library')
        item = result['status']['uplinks'][0]
        self.assertEqual(item['checking'], 1)
        self.assertEqual(item['state'], 'online')
        self.assertEqual(item['operation']['state'], 'timeout')
        self.assertEqual(result['ports']['ports'][0]['rxBytes'], '999999')

    def test_cached_vip_capacity_requires_matching_credentials_and_a_fresh_plan(self):
        env = self.fixture()
        self.response('accounts', env)
        context = json.loads((self.state / 'view-context.json').read_text())
        account = context['accounts'][0]
        (self.state / f'account-plan-{account["key"]}').write_text(f'{account["signature"]}\n{int(time.time())}\nVIP套餐\n')
        self.assertEqual(self.response('accounts', env)['accounts'][0]['maxSessions'], 5)
        cfg = Path(env['MOCK_CONFIG_JSON'])
        cfg.write_text(cfg.read_text().replace('first fixture password', 'new fixture password'))
        self.assertEqual(self.response('accounts', env)['accounts'][0]['maxSessions'], 3)

    def test_ticket_poll_does_not_load_configuration_or_expose_another_owner(self):
        result = self.rpc('billing_poll', {'ticket': '../passwd', 'owner': '1'*32}, BJUT_FUNCTIONS_SH='/missing-library')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['state'], 'error')

    def fault(self, body, action=None):
        work = self.temp / 'work'; work.mkdir()
        pids = self.temp / 'children'
        script = f'. "{base.SCRIPT}"\nWORK_DIR="$TEST_WORK";CFG_TIMEOUT=1;LOCAL_IPV6=2001:db8::1\n{body}\nonline_check\n'
        env = self.environment('online', BJUT_SOURCE_ONLY=1, TEST_WORK=work, TEST_PIDS=pids)
        started = time.monotonic()
        process = subprocess.Popen(['sh', '-c', script], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            if action:
                for _ in range(100):
                    if pids.exists() and len(pids.read_text().splitlines()) >= 6: break
                    time.sleep(.02)
                action(process, work)
            out, err = process.communicate(timeout=6)
            self.assertLess(time.monotonic()-started, 6, (out, err))
            if pids.exists():
                for pid in map(int, pids.read_text().splitlines()):
                    with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
        finally:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            if process.poll() is None: process.communicate()

    def test_probe_worker_exit_without_a_done_marker_is_bounded(self):
        self.fault('probe_target() { return 1; }')

    def test_deleted_probe_directory_stops_and_reaps_the_owned_workers(self):
        import shutil
        self.fault('''probe_target() {
 CHILD_PIDS='';CHILD_TOKENS='';trap children_stop 0;trap 'exit 143' TERM INT HUP
 sleep 60 & child_register "$!";printf '%s\n' "$!" >>"$TEST_PIDS";wait
}''', lambda p, work: shutil.rmtree(work))

    def test_repeated_parent_termination_reaps_both_families_and_their_children(self):
        for i in range(3):
            if i:
                (self.temp / 'work').mkdir(exist_ok=True)
                (self.temp / 'work').rmdir()
                (self.temp / 'children').unlink(missing_ok=True)
            self.fault('''probe_target() {
 CHILD_PIDS='';CHILD_TOKENS='';trap children_stop 0;trap 'exit 143' TERM INT HUP
 sleep 60 & child_register "$!";printf '%s\n' "$!" >>"$TEST_PIDS";wait
}''', lambda p, work: p.terminate())


if __name__ == '__main__':
    unittest.main()
