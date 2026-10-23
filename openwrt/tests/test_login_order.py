#!/usr/bin/env python3
"""Account traversal, rejection cooldowns and per-uplink ordering contracts."""
import json
from pathlib import Path
import unittest
import test_multi_uplink as multi
import test_collaboration as collaboration


class LoginOrderTests(unittest.TestCase):
    setUpClass=classmethod(multi.MultiUplinkTests.setUpClass.__func__)
    tearDownClass=classmethod(multi.MultiUplinkTests.tearDownClass.__func__)
    setUp=multi.MultiUplinkTests.setUp
    tearDown=multi.MultiUplinkTests.tearDown
    environment=multi.MultiUplinkTests.environment
    config=multi.MultiUplinkTests.config
    rpc=multi.MultiUplinkTests.rpc
    run_service=multi.MultiUplinkTests.run_service
    requests=multi.MultiUplinkTests.requests
    status=multi.MultiUplinkTests.status
    shell=collaboration.CollaborationTests.shell

    def test_explicit_rejections_and_environmental_failures_are_distinct(self):
        for message,expected in [('流量已使用完，无法登录',10),('超出流量限制',10),('账户已暂停服务',10),('RADIUS reject R[8222]',10),('',10),('验证码错误',11),('系统繁忙，请稍后再试',11),('流量查询系统错误',11),('Too many requests',11),('Server error',11),('IP地址已锁定',11),('USER ALREADY ONLINE',13)]:
            with self.subTest(message=message):
                file=self.temp/'response';file.write_text('dr1003('+json.dumps({'result':0,'msga':message},ensure_ascii=False)+');')
                value=self.shell('HTTP_CODE=200;HTTP_BODY="$TEST_RESPONSE";parse_login_response;printf "%s" "$?"',TEST_RESPONSE=str(file))
                self.assertEqual(value.stdout,str(expected),value.stderr)
        for body in ['garbled', 'dr1003({"result":2,"msg":"流量已用尽"});','dr1003({"msg":"流量已用尽"});']:
            file.write_text(body)
            value=self.shell('HTTP_CODE=200;HTTP_BODY="$TEST_RESPONSE";parse_login_response;printf "%s" "$?"',TEST_RESPONSE=str(file))
            self.assertEqual(value.stdout,'11',value.stderr)

    def test_dorm_quota_rejection_rotates_then_skips_the_cooling_account(self):
        options=dict(MOCK_LOGIN_TYPE='type1',MOCK_ACCOUNT_COUNT='2',MOCK_DEVICE='eth0',MOCK_TRANSPORT='ethernet',MOCK_IPV4='10.126.19.139',MOCK_FIRST_REJECTION_BODY='dr1005({"result":0,"msg":"认证失败","msga":"本月流量已使用完"});')
        first=self.run_service(scenario='type1_success',**options)
        self.assertEqual(first.returncode,0,first.stderr)
        urls=[line for line in self.requests().splitlines() if line.startswith('URL ') and '/portal/login?' in line]
        self.assertEqual(len(urls),2,urls);self.assertIn('25000001',urls[0]);self.assertIn('25000002',urls[1])
        cache=self.state/'rejected-main-account1';self.assertTrue(cache.exists());self.assertNotIn('first secret',cache.read_text())
        (self.state/'login_succeeded').unlink();(self.state/'requests.log').write_text('')
        second=self.run_service(scenario='type1_success',**options)
        self.assertEqual(second.returncode,0,second.stderr)
        urls=[line for line in self.requests().splitlines() if line.startswith('URL ') and '/portal/login?' in line]
        self.assertEqual(len(urls),1,urls);self.assertIn('25000002',urls[0])

    def test_uplink_orders_survive_settings_and_traverse_independently(self):
        env=self.config()
        for section,order in [('dorm_a','account2 account1'),('dorm_b','account1 account2')]:
            result=self.rpc('uplink_save',{'uplink':section,'payload':json.dumps({'network':'wan14' if section=='dorm_a' else 'wan24','accounts':order})},**env)
            self.assertEqual(json.loads(result.stdout)['state'],'ready',result.stdout+result.stderr)
        config=json.loads(Path(env['MOCK_CONFIG_JSON']).read_text())
        self.assertEqual(config['dorm_a']['accounts'],'account2 account1');self.assertEqual(config['dorm_b']['accounts'],'account1 account2')
        script='''load_configuration;select_uplink "$TEST_UPLINK";login_protocol(){ printf '%s\\n' "$2";return 10; };try_accounts type1'''
        a=self.shell(script,TEST_UPLINK='dorm_a',**env);b=self.shell(script,TEST_UPLINK='dorm_b',**env)
        self.assertEqual(a.stdout.split(),['25000002','25000001'],a.stderr)
        self.assertEqual(b.stdout.split(),['25000001','25000002'],b.stderr)

    def test_rejection_cooldown_is_reset_by_password_change_and_manual_selection(self):
        env=self.config()
        value=self.shell('''load_configuration;select_uplink dorm_a
account_reject account1 type1 25000001 old-password
account_rejection_active account1 type1 25000001 old-password || exit 2
account_rejection_active account1 type1 25000001 new-password && exit 3
config_get password account1 password;account_reject account1 type1 25000001 "$password"
MANUAL_ACCOUNT=account1;login_protocol(){ printf '%s' "$2";return 0; };try_accounts type1''',**env)
        self.assertEqual(value.returncode,0,value.stderr);self.assertEqual(value.stdout,'25000001')
        self.assertFalse((self.state/'rejected-dorm_a-account1').exists())

    def test_gateway_reason_never_logs_echoed_credentials_or_line_controls(self):
        value=self.shell('login_failure_message "$TEST_USER" "$TEST_SECRET" "$TEST_MESSAGE"',TEST_USER='25000001',TEST_SECRET='p$[x].*',TEST_MESSAGE='25000001: p$[x].*\n流量已用尽\x1b[31m')
        self.assertNotIn('25000001',value.stdout);self.assertNotIn('p$[x].*',value.stdout)
        self.assertNotIn('\x1b',value.stdout);self.assertIn('流量已用尽',value.stdout)
        self.assertEqual(len(value.stdout.splitlines()),1)


if __name__=='__main__':unittest.main()
