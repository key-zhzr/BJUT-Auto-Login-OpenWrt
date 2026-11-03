"""Batched workers must keep the old data contract and credential boundaries."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import unittest

import test_multi_uplink as multi
import test_openwrt_port as base


class BatchTests(unittest.TestCase):
    setUpClass = classmethod(multi.MultiUplinkTests.setUpClass.__func__)
    tearDownClass = classmethod(multi.MultiUplinkTests.tearDownClass.__func__)
    setUp = base.OpenWrtPortTests.setUp
    tearDown = base.OpenWrtPortTests.tearDown
    environment = base.OpenWrtPortTests.environment
    config = multi.MultiUplinkTests.config

    @property
    def runtime(self):
        return self.codec.parent/'bjut-runtime'

    def native(self, *args, data=None, env=None):
        return subprocess.run([self.runtime, *map(str, args)], input=data,
                              text=True, capture_output=True, env=env)

    def shell(self, body, **env):
        return subprocess.run(['sh', '-c', f'. "{base.SCRIPT}"; {body}'], text=True,
                              capture_output=True, env=self.environment(
                                  BJUT_SELF=base.SCRIPT, BJUT_SOURCE_ONLY=1, **env))

    def test_hashes_keep_existing_baseline_and_cookie_identifiers(self):
        for value in ('', 'abc', 'a'*1000000, '账号\n密码含引号\'"\\$()\n'):
            result = self.native('sha256', data=value)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), hashlib.sha256(value.encode()).hexdigest())

    def test_projection_assigns_literal_data_and_preserves_empty_last_values(self):
        target = self.temp/'must-not-exist'
        value = f'$(touch {target}) `touch {target}` \' " \\ value'
        source = self.temp/'fields.json'
        source.write_text(json.dumps({'s': value, 'lines': 'first\nsecond', 'rows': [],
                                      'ipv6-address': [{'address': '2001:db8::1'}]}))
        result = self.shell('json_fields "$INPUT" literal=@.s first=@.lines rows=@.rows '\
                            '\'address=@["ipv6-address"][0].address\' last=@.missing; '\
                            'printf "%s\\n%s\\n%s\\n%s\\n<%s>" "$literal" "$first" "$rows" "$address" "$last"', INPUT=source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f'{value}\nfirst\n[]\n2001:db8::1\n<>')
        self.assertFalse(target.exists())
        for bad in ('X;touch=@.s', 'X=@["missing', 'X=@[999999999999999999999999]'):
            result = self.native('fields', source, bad)
            self.assertIn(result.returncode, (0, 2))
            self.assertFalse(target.exists())

    def prepare(self):
        env = self.config()
        env.update(BJUT_CONFIG_FILE=env['MOCK_CONFIG_JSON'], BJUT_CONFIG_DELTA=str(self.temp/'delta'))
        result = self.shell('validate_configuration && prepared_context_write', **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return env

    def test_prepared_metadata_has_no_plaintext_secrets_and_needs_no_uci_reload(self):
        env = self.prepare()
        file = self.state/'prepared-context.json'
        context = json.loads(file.read_text())
        self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        self.assertNotIn('fixture password', file.read_text())
        account = context['sections']['account1']
        self.assertNotIn('password', account)
        self.assertEqual(account['bjut_signature'], hashlib.sha256(b'25000001\nfirst fixture password\n').hexdigest())
        functions = self.temp/'no-reload.sh'
        functions.write_text(f'. "{base.MOCKS / "functions.sh"}"\nconfig_load() {{ return 99; }}\n')
        result = self.shell('validate_configuration && select_uplink dorm_a && account_metadata account1 && '\
                            'printf "%s|%s|%s" "$CONFIG_PREPARED" "$CFG_NETWORK" "$ACCOUNT_KEY"',
                            BJUT_PREPARED_CONFIG=1, BJUT_FUNCTIONS_SH=functions, **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '1|wan14|'+hashlib.sha256(b'25000001').hexdigest())

    def test_credentials_are_lazy_and_configuration_change_clears_destination(self):
        env = self.prepare()
        result = self.shell('load_configuration; select_uplink dorm_a; credential_get secret account1; '\
                            'test "$secret" = "first fixture password"; test "$CONFIG_PREPARED" = 0',
                            BJUT_PREPARED_CONFIG=1, **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.shell('load_configuration; secret=old; printf " " >>"$BJUT_CONFIG_FILE"; '\
                            'credential_get secret account1 && exit 7; test -z "$secret"',
                            BJUT_PREPARED_CONFIG=1, **env)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_private_snapshot_permissions_and_same_second_edits_are_checked(self):
        env = self.prepare()
        file = self.state/'prepared-context.json'
        args = ('prepared-config', file, env['BJUT_CONFIG_FILE'], env['BJUT_CONFIG_DELTA'])
        file.chmod(0o644)
        native_env = {**os.environ, 'BJUT_NATIVE_ADDRESSES':str(env['BJUT_NATIVE_ADDRESSES'])}
        self.assertEqual(self.native(*args, env=native_env).returncode, 75)
        self.assertEqual(self.native('network-read', self.state/'network-context.json', self.sys_net,
                                     'wan14', '', 'wan16', '', '', '', signature, env=native_env).returncode, 0)
        file.chmod(0o600)
        self.assertEqual(self.native(*args).returncode, 0)
        config = Path(env['BJUT_CONFIG_FILE']);stat = config.stat()
        config.write_text(config.read_text().replace('25000001', '25000009'))
        os.utime(config, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        result = self.native(*args)
        self.assertEqual(result.returncode, 75)
        self.assertEqual(result.stdout, '')

    def test_native_rows_match_legacy_wrappers_units_mac_and_scope(self):
        (self.state/'traffic-identities.tsv').write_text('interface:lan3\tlan3\taabbccddeeff\t2001:db8::1\n')
        rows = [
            {'sessionId': 'private-1', 'mac': 'AA:BB:CC:DD:EE:FF', 'ip': '192.0.2.1', 'loginTime': 'a', 'downFlow': '1024.512', 'upFlow': 99999},
            {'sessionId': 'private-2', 'mac': None, 'ipv6': '2001:0db8:0:0:0:0:0:1', 'downFlow': 0},
            {'sessionId': 'private-3', 'mac': '11-22-33-44-55-66', 'ip': '192.0.2.3', 'downFlow': '-1'},
            {'sessionId': 'private-4', 'mac': '7788.99aa.bbcc', 'ip': '192.0.2.4', 'downFlow': None},
        ]
        source = self.temp/'online.json'
        for wrapped in (rows, {'rows': rows}, {'data': rows}, [], None, {'error': 'not a list'}):
            source.write_text(json.dumps(wrapped))
            for scope in ('local', 'all'):
                body = '. "$LIB_DIR/billing.sh"; . "$JSHN_SH"; CFG_TRAFFIC_SCOPE="$SCOPE"; traffic_rows "$INPUT"'
                old = self.shell(body, INPUT=source, SCOPE=scope, BJUT_BATCH_DISABLE=1)
                new = self.shell(body, INPUT=source, SCOPE=scope)
                self.assertEqual(new.returncode, 0, new.stderr)
                self.assertEqual(json.loads(new.stdout), json.loads(old.stdout), (wrapped, scope))
                self.assertNotIn('private-', new.stdout)

    def test_ingest_keeps_old_keys_deltas_intervals_and_duplicate_handling(self):
        source = self.temp/'online.json';account = hashlib.sha256(b'25000001').hexdigest()
        states = {}
        for mode in ('native', 'legacy'):
            state = self.temp/mode;state.mkdir();states[mode] = state
            (state/'traffic-identities.tsv').write_text('interface:lan3\tlan3\taabbccddeeff\t192.0.2.1\n')
        at = 1792886400
        for step, (down, seconds) in enumerate(((10240, 0), (12288, 60), (1024, 60), (13312, 60), (20480, 181))):
            at += seconds
            row = {'sessionId': 'private', 'loginTime': '2026-10-25 08:00:00', 'mac': 'AA:BB:CC:DD:EE:FF', 'ip': '192.0.2.1', 'downFlow': down}
            source.write_text(json.dumps([row, row]))
            snapshots = {}
            for mode, state in states.items():
                result = self.shell('. "$LIB_DIR/billing.sh"; . "$JSHN_SH"; CFG_TRAFFIC_SCOPE=all; '\
                                    'traffic_history_record "$KEY" "$INPUT" "$AT" || exit 3; '\
                                    'traffic_history_stream curves',
                                    INPUT=source, KEY=account, AT=at, BJUT_STATE_DIR=state,
                                    BJUT_BATCH_DISABLE=int(mode == 'legacy'),
                                    BJUT_TRAFFIC_HISTORY=state/'persisted.tsv', BJUT_TRAFFIC_CURVES=state/'curves.tsv')
                self.assertEqual(result.returncode, 0, result.stderr)
                snapshots[mode] = sorted(result.stdout.splitlines())
            self.assertEqual(snapshots['native'], snapshots['legacy'], step)
            def baselines(state):
                return {p.name: p.read_text() for p in (state/'traffic-baselines').iterdir()}
            self.assertEqual(baselines(states['native']), baselines(states['legacy']))

    def network_fixture(self):
        env = self.prepare()
        data = json.loads(Path(env['MOCK_NETWORK_JSON']).read_text())
        data['wan16']['ipv6-prefix'] = [{'address': '2001:da8:216:10::', 'mask': 64}]
        dump = {'interface': [dict(v, interface=k) for k,v in data.items()]}
        signature = json.loads((self.state/'prepared-context.json').read_text())['fingerprint']
        result = self.native('network-save', self.state/'network-context.json', signature, data=json.dumps(dump))
        self.assertEqual(result.returncode, 0, result.stderr)
        addresses = self.temp/'addresses.json'
        addresses.write_text(json.dumps([
            {'device':'lan3','ip':'10.126.19.139'},
            {'device':'lan4','ip':'10.126.20.139'},
            {'device':'lan6','ip':'2001:da8:216::123'},
            {'device':'lan6','ip':'2001:da8:216::bad','unusable':1},
        ]))
        env.update(BJUT_NATIVE_ADDRESSES=addresses, BJUT_PREPARED_CONFIG=1)
        return env, signature

    def test_network_projection_uses_the_correct_family_and_current_kernel_source(self):
        env, signature = self.network_fixture()
        body = 'load_configuration;select_uplink dorm_a;read_network_identity || exit 2; '\
               'printf "%s|%s|%s|%s" "$DEVICE" "$LOCAL_IPV4" "$DEVICE6" "$LOCAL_IPV6"'
        result = self.shell(body, **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'lan3|10.126.19.139|lan6|2001:da8:216::123')
        args = ('network-read', self.state/'network-context.json', self.sys_net,
                'wan14', 'lan4', 'wan16', '', '', '', signature)
        self.assertEqual(self.native(*args).returncode, 75)
        file = self.state/'network-context.json';stat = file.stat()
        os.utime(file, (stat.st_atime, stat.st_mtime-6))
        self.assertEqual(self.native('network-read', file, self.sys_net, 'wan14', '', 'wan16', '', '', '', signature, env=native_env).returncode, 75)

    def test_native_inventory_deduplicates_physical_devices_and_skips_unusable_addresses(self):
        env, signature = self.network_fixture()
        context_file = self.state/'prepared-context.json'
        context = json.loads(context_file.read_text())
        context['sections']['duplicate'] = dict(context['sections']['dorm_a'])
        context_file.write_text(json.dumps(context))
        # Native commands inherit the fixture only when explicitly supplied.
        result = subprocess.run([self.runtime, 'network-identities', self.state/'network-context.json',
                                 self.state/'prepared-context.json', self.sys_net,
                                 self.state/'identities.tsv', signature], capture_output=True,
                                env={**os.environ, 'BJUT_NATIVE_ADDRESSES':str(env['BJUT_NATIVE_ADDRESSES'])})
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = (self.state/'identities.tsv').read_text().splitlines()
        self.assertEqual(len(rows), len(set(rows)))
        self.assertIn('interface:lan3\tlan3\t-\t10.126.19.139', rows)
        self.assertIn('interface:lan6\tlan6\t-\t2001:da8:216::123', rows)
        self.assertFalse(any('::bad' in r for r in rows))


if __name__ == '__main__':
    unittest.main()
