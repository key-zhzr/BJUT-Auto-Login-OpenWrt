#!/usr/bin/env python3
"""Small offline PushPlus checks. No real notification service is contacted."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

import test_openwrt_port as base
import test_multi_uplink as multi


class PushPlusTests(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix='bjut-pushplus-'))
        self.state = self.temp / 'state'
        self.state.mkdir()
        # The older lightweight mock only escapes single-line JSON strings.
        self.jshn = self.temp / 'jshn.sh'
        self.jshn.write_text((base.MOCKS / 'jshn.sh').read_text() + '''
_json_escape() {
 printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read(),ensure_ascii=False)[1:-1],end="")'
}
''')
        self.curl = self.temp / 'curl'
        self.curl.write_text('''#!/usr/bin/env python3
import json,os,sys,time,uuid
from pathlib import Path
args=sys.argv[1:]
body=json.load(sys.stdin)
directory=Path(os.environ['BJUT_STATE_DIR'])/'requests'
directory.mkdir(exist_ok=True)
name=directory/(uuid.uuid4().hex+'.json')
temporary=name.with_suffix('.tmp')
temporary.write_text(json.dumps({'args':args,'body':body},ensure_ascii=False))
temporary.replace(name)
time.sleep(float(os.environ.get('MOCK_PUSHPLUS_WAIT','0')))
output=Path(args[args.index('--output')+1])
output.write_text(json.dumps({'code':int(os.environ.get('MOCK_PUSHPLUS_CODE','200')),'msg':body['token']}))
print(os.environ.get('MOCK_PUSHPLUS_HTTP','200'),end='')
''')
        self.curl.chmod(0o755)
        self.env = dict(os.environ, BJUT_SOURCE_ONLY='1', BJUT_SELF=str(base.SCRIPT),
                        BJUT_LIB_DIR=str(base.CORE / 'files/usr/lib/bjut-autologin'),
                        BJUT_JSHN_SH=str(self.jshn), BJUT_CURL=str(self.curl),
                        BJUT_JSONFILTER=str(base.MOCKS / 'jsonfilter.py'),
                        BJUT_LOGGER=str(base.MOCKS / 'logger.sh'),
                        BJUT_STATE_DIR=str(self.state), MOCK_STATE_DIR=str(self.state))

    def tearDown(self):
        self.wait_senders()
        shutil.rmtree(self.temp)

    def dispatch(self, state, uplink='dorm_a', account='25000001', **extra):
        env = {**self.env, 'TEST_UPLINK':uplink, 'TEST_ACCOUNT':account, 'TEST_ENABLED':'1', **extra}
        script = '''. "$BJUT_SELF"
CFG_PUSHPLUS_ENABLED="$TEST_ENABLED"; CFG_PUSHPLUS_TOKEN=fixture-pushplus-secret
CFG_PUSHPLUS_TOPIC=fixture_group; CFG_PUSHPLUS_ONLINE=1; CFG_PUSHPLUS_FAILURE=1
CFG_PUSHPLUS_DELAY=60; CFG_PUSHPLUS_INTERVAL=3600
UPLINK_ID="$TEST_UPLINK"; CFG_NETWORK="wan_$UPLINK_ID"; DEVICE=lan3
PROBE4=reachable; PROBE6=not_configured
STATE_FILE="$STATE_DIR/uplink-$UPLINK_ID.json"
if [ "$1" = test ]; then pushplus_queue_test
else write_status "$1" "fixture $1" bjut-sushe "$TEST_ACCOUNT" 0 0 0; fi
'''
        return subprocess.run(['sh', '-c', script, 'fixture', state], env=env,
                              capture_output=True, text=True, timeout=5)

    def records(self):
        paths = sorted((self.state / 'requests').glob('*.json'), key=lambda p: p.stat().st_mtime_ns)
        return [json.loads(p.read_text()) for p in paths]

    def wait_senders(self):
        deadline = time.monotonic() + 6
        while list((self.state / 'pushplus').glob('*/sending')) and time.monotonic() < deadline:
            time.sleep(.05)
        self.assertEqual(list((self.state / 'pushplus').glob('*/sending')), [])

    def test_login_is_nonblocking_and_token_stays_out_of_status_arguments_and_logs(self):
        self.dispatch('login_accepted')
        self.assertEqual(self.records(), [])
        start = time.monotonic()
        result = self.dispatch('online', MOCK_PUSHPLUS_WAIT='3')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(time.monotonic() - start, 2.5)
        self.wait_senders()
        self.dispatch('online')
        self.wait_senders()
        [record] = self.records()
        self.assertIn('登录成功', record['body']['title'])
        self.assertIn('wan_dorm_a', record['body']['content'])
        self.assertIn('\n账号：25000001\n', record['body']['content'])
        self.assertEqual(record['body']['token'], 'fixture-pushplus-secret')
        self.assertEqual(record['body']['topic'], 'fixture_group')
        self.assertEqual(record['body']['template'], 'txt')
        self.assertEqual(record['args'][-1], 'https://www.pushplus.plus/send')
        self.assertIn('--max-time', record['args'])
        for forbidden in ('--interface', '--insecure', '--location', 'fixture-pushplus-secret'):
            self.assertNotIn(forbidden, record['args'])
        self.assertNotIn('fixture-pushplus-secret', (self.state / 'uplink-dorm_a.json').read_text())
        self.assertNotIn('fixture-pushplus-secret', (self.state / 'logger.log').read_text())
        self.assertIn('已受理消息', (self.state / 'logger.log').read_text())

    def test_transient_outages_are_silent_and_sustained_outages_recover_independently(self):
        self.dispatch('online')  # Already online when the service starts: silent.
        self.dispatch('request_failed')
        self.dispatch('online')
        self.assertEqual(self.records(), [])
        self.dispatch('request_failed')
        path = self.state / 'pushplus/dorm_a/state.json'
        value = json.loads(path.read_text()); value['since'] -= 61; path.write_text(json.dumps(value))
        self.dispatch('cooldown')
        self.wait_senders()
        self.dispatch('cooldown')
        self.wait_senders()
        self.assertEqual(len(self.records()), 1)
        self.dispatch('auth_rejected', uplink='dorm_b')
        self.wait_senders()
        self.assertEqual(len(self.records()), 2)
        self.dispatch('online')
        self.wait_senders()
        self.assertIn('恢复联网', self.records()[-1]['body']['title'])
        self.dispatch('logged_out')
        self.wait_senders()
        self.assertEqual(len(self.records()), 3)

    def test_failed_api_response_is_not_success_and_new_recovery_replaces_it(self):
        self.dispatch('auth_rejected', MOCK_PUSHPLUS_CODE='500')
        self.wait_senders()
        path = self.state / 'pushplus/dorm_a/pending.json'
        self.assertTrue(path.exists())
        self.assertNotIn('已受理消息', (self.state / 'logger.log').read_text())
        self.dispatch('auth_rejected', MOCK_PUSHPLUS_CODE='500')
        self.wait_senders()
        self.assertEqual(len(self.records()), 1)
        self.dispatch('online')
        self.wait_senders()
        self.assertEqual(len(self.records()), 2)
        self.assertIn('恢复联网', self.records()[-1]['body']['title'])
        self.assertFalse(path.exists())
        # A queued failure must also be discarded on intentional logout.
        self.dispatch('auth_rejected', uplink='dorm_b', MOCK_PUSHPLUS_CODE='500')
        self.wait_senders()
        self.dispatch('logged_out', uplink='dorm_b')
        self.assertFalse((self.state / 'pushplus/dorm_b/pending.json').exists())

    def test_default_disabled_and_test_messages_do_not_share_an_uplink_namespace(self):
        self.dispatch('auth_rejected', TEST_ENABLED='0')
        self.assertEqual(self.records(), [])
        self.assertFalse((self.state / 'pushplus').exists())
        self.dispatch('test')
        self.wait_senders()
        self.assertIn('测试消息', self.records()[0]['body']['title'])
        self.assertEqual(self.dispatch('test').returncode, 2)
        self.dispatch('auth_rejected', uplink='test')
        self.wait_senders()
        self.assertEqual(len(self.records()), 2)
        self.assertTrue((self.state / 'pushplus/.test/state.json').exists())
        self.assertTrue((self.state / 'pushplus/test/state.json').exists())


class PushPlusSettingsTests(unittest.TestCase):
    setUpClass = classmethod(multi.MultiUplinkTests.setUpClass.__func__)
    tearDownClass = classmethod(multi.MultiUplinkTests.tearDownClass.__func__)
    setUp = multi.MultiUplinkTests.setUp
    tearDown = multi.MultiUplinkTests.tearDown
    environment = multi.MultiUplinkTests.environment
    config = multi.MultiUplinkTests.config
    rpc = multi.MultiUplinkTests.rpc

    def test_settings_hide_token_keep_blank_replacement_and_validate_before_writing(self):
        env = self.config()
        path = Path(env['MOCK_CONFIG_JSON'])
        original = json.loads(path.read_text())
        original['main'].update(pushplus_enabled='1', pushplus_token='fixture-private-token')
        path.write_text(json.dumps(original))
        response = self.rpc('settings', {}, **env)
        self.assertEqual(response.returncode, 0, response.stderr)
        service = json.loads(response.stdout)['service']
        self.assertEqual(service['pushplus_has_token'], '1')
        self.assertEqual(service['pushplus_token'], '')
        self.assertNotIn('fixture-private-token', response.stdout)
        result = self.rpc('save_settings', {'pushplus_token':'', 'pushplus_enabled':'1', 'pushplus_interval':'600'}, **env)
        self.assertEqual(json.loads(result.stdout)['state'], 'ready', result.stderr)
        saved = json.loads(path.read_text())
        self.assertEqual(saved['main']['pushplus_token'], 'fixture-private-token')
        self.assertEqual(saved['main']['pushplus_interval'], '600')
        before = path.read_bytes()
        result = self.rpc('save_settings', {'pushplus_enabled':'1', 'pushplus_interval':'0'}, **env)
        self.assertEqual(json.loads(result.stdout)['state'], 'error')
        self.assertEqual(path.read_bytes(), before)
        listing = subprocess.check_output(['sh', str(multi.RPC), 'list'], text=True)
        self.assertIn('pushplus_test', json.loads(listing))


if __name__ == '__main__':
    unittest.main()
