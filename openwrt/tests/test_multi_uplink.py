#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import unittest
import test_openwrt_port as base
import time

CORE = base.CORE
MOCKS = base.MOCKS
RPC = CORE / 'files/usr/libexec/rpcd/bjut-autologin'


class MultiUplinkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        base.OpenWrtPortTests.setUpClass()
        cls.codec = base.OpenWrtPortTests.codec
        cls.html = base.OpenWrtPortTests.build_dir / 'bjut-html'
        subprocess.run(['cc', '-std=c99', '-O2', '-Wall', '-Wextra', '-Werror',
                        str(CORE / 'src/bjut-html.c'), '-o', str(cls.html)], check=True)

    @classmethod
    def tearDownClass(cls):
        base.OpenWrtPortTests.tearDownClass()

    setUp = base.OpenWrtPortTests.setUp
    tearDown = base.OpenWrtPortTests.tearDown
    environment = base.OpenWrtPortTests.environment
    run_service = base.OpenWrtPortTests.run_service
    requests = base.OpenWrtPortTests.requests
    status = base.OpenWrtPortTests.status

    def rpc(self, method, payload, **env):
        scenario = env.pop('MOCK_SCENARIO', 'online')
        return subprocess.run(['sh', str(RPC), 'call', method], input=json.dumps(payload),
                              text=True, capture_output=True,
                              env=self.environment(scenario, BJUT_SELF=base.SCRIPT, **env))

    def config(self):
        for device in ('lan3', 'lan4', 'lan6'):
            (self.sys_net / device).mkdir()
        path = self.temp / 'config'
        path.mkdir()
        config = {
            'main': {'.type':'service', 'enabled':'1', 'timeout':'1', 'interval':'5', 'max_backoff':'20', 'post_login_delay':'0', 'online_url':'http://connect.test/generate_204'},
            'dorm_a': {'.type':'uplink', 'enabled':'1', 'network':'wan14', 'network6':'wan16', 'login_type':'type1', 'transport':'ethernet', 'accounts':['account1']},
            'dorm_b': {'.type':'uplink', 'enabled':'1', 'network':'wan24', 'network6':'wan26', 'login_type':'type1', 'transport':'ethernet', 'accounts':['account2']},
            'account1': {'.type':'account','enabled':'1','username':'25000001','password':'first fixture password'},
            'account2': {'.type':'account','enabled':'1','username':'25000002','password':'second fixture password'},
        }
        cfg = path / 'bjut-autologin'; cfg.write_text(json.dumps(config))
        networks = {
            'wan14':{'up':True,'l3_device':'lan3','ipv4-address':[{'address':'10.126.19.139'}]},
            'wan16':{'up':True,'l3_device':'lan6','ipv6-address':[{'address':'2001:da8:216::123'}]},
            'wan24':{'up':True,'l3_device':'lan4','ipv4-address':[{'address':'10.126.20.139'}]},
            'wan26':{'up':False,'l3_device':'lan4'},
        }
        net = self.temp / 'networks.json'; net.write_text(json.dumps(networks))
        return {'MOCK_CONFIG_JSON':str(cfg), 'MOCK_NETWORK_JSON':str(net),
                'BJUT_UCI':str(MOCKS / 'uci.py'), 'BJUT_CONFIG_DIR':str(path),
                'MOCK_UCI_TRACE':str(self.temp / 'uci-trace')}

    def test_confirmed_session_preserves_login_when_all_public_targets_fail(self):
        result = self.run_service(scenario='portal_online', MOCK_LOGIN_TYPE='type1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status()['state'], 'authenticated_limited')
        self.assertEqual(self.status()['session'], 'online')
        self.assertEqual(self.status()['offline_count'], 0)
        self.assertNotIn('/eportal/portal/login?', self.requests())

    def test_public_preauth_allowlist_does_not_hide_explicitly_offline_session(self):
        self.run_service(command='once', scenario='preauth_public', MOCK_LOGIN_TYPE='type1')
        self.assertEqual(self.status()['state'], 'offline_suspected')
        self.assertEqual(self.status()['session'], 'offline')

    def test_unknown_session_does_not_replace_previously_good_login(self):
        self.run_service(scenario='online')
        self.run_service(command='once', scenario='portal_unknown', MOCK_LOGIN_TYPE='type1')
        self.assertEqual(self.status()['state'], 'probe_uncertain')
        self.assertNotIn('/eportal/portal/login?', self.requests())

    def test_ipv6_can_prove_connectivity_when_ipv4_is_unreachable(self):
        self.run_service(scenario='ipv6_only', MOCK_IPV6='2001:da8:216::123')
        item = self.status()
        self.assertEqual(item['state'], 'online')
        self.assertEqual(item['internet4'], 'unreachable')
        self.assertEqual(item['internet6'], 'reachable')

    def test_redundant_https_target_accepts_verified_transport_without_exact_204(self):
        self.run_service(scenario='public_tls')
        self.assertEqual(self.status()['state'], 'online')
        self.assertIn('www.baidu.com:443:110.242.69.21', self.requests())

    def test_multiple_uplinks_have_separate_accounts_addresses_and_status(self):
        env = self.config()
        result = self.run_service(scenario='multi_mapped', **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = self.status()
        self.assertEqual(len(data['uplinks']), 2)
        a, b = data['uplinks']
        self.assertEqual((a['network'], a['device6'], a['account']), ('wan14','lan6','25***01'))
        self.assertEqual((b['network'], b['account']), ('wan24','25***02'))
        self.assertEqual(a['ipv6'], '2001:da8:216::123')
        self.assertEqual(b['internet6'], 'not_configured')
        self.assertIn('ifhost!lan6!2001:da8:216::123', self.requests())
        self.assertIn('wlan_user_ipv6=2001%3Ada8%3A216%3A%3A123', self.requests())

    def test_four_numeric_uplinks_work_without_cksum_and_have_distinct_routes(self):
        env=self.config(); cfg=json.loads(Path(env['MOCK_CONFIG_JSON']).read_text())
        nets=json.loads(Path(env['MOCK_NETWORK_JSON']).read_text())
        cfg['1']=cfg.pop('dorm_a'); cfg['2']=cfg.pop('dorm_b')
        for i, dev in enumerate(('lan3','lan4','lan5','eth1.41'),1):
            (self.sys_net/dev).mkdir(exist_ok=True)
            cfg.setdefault(str(i),{'.type':'uplink','enabled':'1','network':f'wan{i}4','login_type':'type1','transport':'ethernet','accounts':['account1' if i%2 else 'account2']})
            nets[f'wan{i}4']={'up':True,'l3_device':dev,'ipv4-address':[{'address':f'10.126.{18+i}.139'}], 'route':[{'target':'0.0.0.0','mask':0,'nexthop':f'10.126.{18+i}.254'}]}
        Path(env['MOCK_CONFIG_JSON']).write_text(json.dumps(cfg)); Path(env['MOCK_NETWORK_JSON']).write_text(json.dumps(nets))
        tools=self.temp/'missing-tool'; tools.mkdir(); stub=tools/'cksum'
        stub.write_text('#!/bin/sh\necho cksum-must-not-be-required >&2\nexit 127\n'); stub.chmod(0o755)
        trace=self.temp/'routes.log'
        result=self.run_service(scenario='multi_mapped',PATH=str(tools)+os.pathsep+os.environ['PATH'],MOCK_ROUTE_TRACE=trace,**env)
        self.assertEqual(result.returncode,0,result.stderr)
        items=self.status()['uplinks']; self.assertEqual(len(items),4)
        self.assertTrue(all(item['state']=='online' and item['route4']=='managed' for item in items),items)
        tables=[p.read_text().split()[1] for p in self.state.glob('routes-*-4')]
        self.assertEqual(len(set(tables)),4)
        self.assertNotIn('cksum-must-not-be-required',result.stderr)

    def test_source_contention_preserves_the_last_completed_result(self):
        env=self.config(); self.run_service(scenario='multi_mapped',**env)
        previous=json.loads((self.state/'uplink-dorm_a.json').read_text())
        lock=self.state/'source-lan3-10.126.19.139.lock'; lock.mkdir()
        (lock/'pid').write_text(str(os.getpid()))
        result=subprocess.run(['sh',str(base.SCRIPT),'once','dorm_a'],env=self.environment('multi_mapped',**env),capture_output=True,text=True)
        self.assertEqual(result.returncode,75)
        self.assertEqual(json.loads((self.state/'uplink-dorm_a.json').read_text()),previous)

    def test_status_exposes_progress_without_replacing_online_snapshot(self):
        env=self.config(); self.run_service(scenario='multi_mapped',**env)
        worker=subprocess.Popen(['sh',str(base.SCRIPT),'once','dorm_a'],env=self.environment('multi_mapped',MOCK_PROBE_DELAY='.5',**env),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            for _ in range(100):
                if (self.state/'phase-dorm_a').exists(): break
                time.sleep(.02)
            response=self.rpc('status',{},**env); item=json.loads(response.stdout)['uplinks'][0]
            self.assertEqual(item['state'],'online'); self.assertEqual(item['checking'],1); self.assertTrue(item['check_message'])
            worker.communicate(timeout=20)
            self.assertFalse((self.state/'phase-dorm_a').exists())
        finally:
            if worker.poll() is None: worker.kill(); worker.communicate()

    def test_disabled_managed_routes_prune_old_tables_even_with_globbing_disabled(self):
        env=self.config(); cfg=json.loads(Path(env['MOCK_CONFIG_JSON']).read_text()); nets=json.loads(Path(env['MOCK_NETWORK_JSON']).read_text())
        nets['wan14']['route']=[{'target':'0.0.0.0','mask':0,'nexthop':'10.126.19.254'}]
        Path(env['MOCK_NETWORK_JSON']).write_text(json.dumps(nets)); trace=self.temp/'routes.log'
        self.run_service(scenario='multi_mapped',MOCK_ROUTE_TRACE=trace,**env)
        self.assertTrue(list(self.state.glob('routes-*-*')))
        cfg['main']['managed_routes']='0'; Path(env['MOCK_CONFIG_JSON']).write_text(json.dumps(cfg))
        self.run_service(scenario='multi_mapped',MOCK_ROUTE_TRACE=trace,**env)
        self.assertFalse(list(self.state.glob('routes-*-*')))

    def test_new_source_address_drops_old_credential_cooldown(self):
        self.run_service(scenario='auth_rejected')
        self.run_service(command='once', scenario='type2_success', MOCK_IPV4='10.21.2.4', MOCK_OFFLINE_CONFIRMATIONS='1')
        self.assertEqual(self.status()['state'], 'online')

    def test_sync_updates_existing_account_and_keeps_other_accounts_and_uplink_assignment(self):
        env = self.config()
        password = "p ' \\" + '🙂'
        response = self.rpc('sync_accounts', {'payload':json.dumps({'accounts':[{'user':'25000001','pass':password,'enabled':False}]})}, **env)
        self.assertEqual(response.returncode, 0, response.stderr)
        self.assertEqual(json.loads(response.stdout)['state'], 'ready')
        cfg = json.loads(Path(env['MOCK_CONFIG_JSON']).read_text())
        self.assertEqual(cfg['account1']['password'], password)
        self.assertEqual(cfg['account1']['enabled'], '0')
        self.assertEqual(cfg['account2']['password'], 'second fixture password')
        self.assertEqual(cfg['dorm_a']['accounts'], ['account1'])
        self.assertNotIn(password, Path(env['MOCK_UCI_TRACE']).read_text())
        self.assertNotIn(password, response.stdout)

    def test_invalid_sync_cannot_partially_overwrite_configuration(self):
        env = self.config()
        original = Path(env['MOCK_CONFIG_JSON']).read_bytes()
        response = self.rpc('sync_accounts', {'payload':json.dumps({'accounts':[{'user':'25000001','pass':'new pass','enabled':True}, {'user':'bad;reboot','pass':'secret','enabled':True}]})}, **env)
        self.assertEqual(json.loads(response.stdout)['state'], 'error')
        self.assertEqual(Path(env['MOCK_CONFIG_JSON']).read_bytes(), original)

    def test_billing_poll_requires_the_ticket_owner_and_has_no_arbitrary_file_path(self):
        env = self.config()
        response = self.rpc('billing_poll', {'ticket':'../passwd','owner':'1'*32}, **env)
        self.assertEqual(json.loads(response.stdout)['state'], 'error')
        self.assertNotIn('root:', response.stdout)

    def test_mwan_rules_match_only_selected_source_and_preserve_existing_policies(self):
        env = self.config()
        cfg_dir = Path(env['BJUT_CONFIG_DIR'])
        mwan = cfg_dir / 'mwan3'
        mwan.write_text(json.dumps({'globals':{'.type':'globals','mmx_mask':'0x7f00'}, 'default_rule':{'.type':'rule','use_policy':'balanced'}}))
        self.run_service(scenario='multi_mapped', BJUT_MWAN_CONFIG=mwan, **env)
        data = json.loads(mwan.read_text())
        self.assertEqual(data['default_rule']['use_policy'], 'balanced')
        rules = [v for v in data.values() if v.get('bjut_managed') == '1']
        self.assertEqual({v['src_ip'] for v in rules}, {'10.126.19.139/32','10.126.20.139/32','2001:da8:216::123/128'})
        self.assertTrue(all(v['use_policy']=='default' for v in rules))

    def billing(self, scenario, env, account='account1', uplink='dorm_a'):
        owner = '1'*32
        response = self.rpc('billing_start', {'uplink':uplink, 'account':account, 'owner':owner},
                            BJUT_BILLING=CORE / 'files/usr/libexec/bjut-billing', BJUT_HTML=self.html,
                            MOCK_SCENARIO=scenario, **env)
        self.assertEqual(response.returncode, 0, response.stderr)
        ticket = json.loads(response.stdout)['ticket']
        return ticket, owner

    def billing_poll(self, ticket, owner, env):
        for _ in range(100):
            result = self.rpc('billing_poll', {'ticket':ticket,'owner':owner}, **env)
            value = json.loads(result.stdout)
            if value.get('result',{}).get('state') != 'loading': return value
            time.sleep(.1)
        self.fail('billing worker did not complete')

    def test_billing_is_bound_to_chosen_upstream_and_sanitizes_dashboard_and_sessions(self):
        env = self.config()
        ticket, owner = self.billing('billing_success', env)
        value = self.billing_poll(ticket, owner, env)
        self.assertEqual(value['result']['state'], 'ready', value)
        self.assertEqual(value['result']['account'], '25000001')
        self.assertEqual(value['result']['balance'], '42')
        self.assertEqual(value['result']['accountStatus'].strip(), '正常')
        self.assertEqual(value['sessions'][0]['ip'], '10.126.19.139')
        self.assertTrue(value['sessionsAvailable'])
        self.assertNotIn('userPassword', json.dumps(value))
        self.assertNotIn('do not expose', json.dumps(value))
        self.assertIn('ifhost!lan3!10.126.19.139', self.requests())
        self.assertIn('jfself.bjut.edu.cn:443:172.21.0.16', self.requests())
        self.assertIn('URL https://jfself.bjut.edu.cn/Self/static/login.js', self.requests())
        self.assertNotIn('URL https://other.test/', self.requests())
        before=self.requests().count('URL https://jfself.bjut.edu.cn/Self/login/verify')
        ticket2, owner2=self.billing('billing_success',env)
        second=self.billing_poll(ticket2,owner2,env)
        self.assertEqual(second['result']['state'],'ready')
        self.assertEqual(self.requests().count('URL https://jfself.bjut.edu.cn/Self/login/verify'), before)

    def test_billing_overview_remains_available_when_online_devices_endpoint_fails(self):
        env=self.config(); ticket,owner=self.billing('billing_sessions_unavailable',env)
        value=self.billing_poll(ticket,owner,env)
        self.assertEqual(value['result']['state'],'ready',value)
        self.assertEqual(value['result']['balance'],'42')
        self.assertFalse(value['sessionsAvailable'])
        self.assertEqual(value['sessions'],[])

    def test_wrong_billing_password_is_not_misclassified_as_captcha(self):
        env=self.config(); ticket,owner=self.billing('billing_rejected',env)
        value=self.billing_poll(ticket,owner,env)
        self.assertEqual(value['result']['state'],'error')
        self.assertEqual(value['result']['message'],'账号或密码错误')

    def test_billing_current_account_prefers_signed_sso_without_saved_password(self):
        env=self.config(); cfg=json.loads(Path(env['MOCK_CONFIG_JSON']).read_text())
        cfg['account1']['password']=''; cfg['account2']['enabled']='0'
        Path(env['MOCK_CONFIG_JSON']).write_text(json.dumps(cfg))
        ticket,owner=self.billing('billing_sso',env,account='current')
        value=self.billing_poll(ticket,owner,env)
        self.assertEqual(value['result']['state'],'ready',value)
        self.assertEqual(value['result']['account'],'25000099')
        self.assertEqual(value['result']['access'],'当前认证账号')
        self.assertNotIn('/Self/login/verify',self.requests())
        self.assertNotIn('userPassword',json.dumps(value))
        self.assertIn('ifhost!lan3!10.126.19.139',self.requests())

    def test_billing_different_manual_account_does_not_inherit_current_sso_account(self):
        env=self.config(); ticket,owner=self.billing('billing_sso',env,account='account2')
        value=self.billing_poll(ticket,owner,env)
        self.assertEqual(value['result']['account'],'25000002',value)
        self.assertEqual(value['result']['access'],'已保存账号')
        self.assertIn('/Self/login/verify',self.requests())

    def test_billing_foreign_sso_url_is_rejected_before_session_token_is_sent(self):
        env=self.config(); ticket,owner=self.billing('billing_sso_foreign',env)
        value=self.billing_poll(ticket,owner,env)
        self.assertEqual(value['result']['state'],'ready',value)
        self.assertEqual(value['result']['account'],'25000001')
        self.assertNotIn('URL https://foreign.invalid',self.requests())

    def test_billing_old_curl_without_enabled_source_wrapper_sends_no_request(self):
        env=self.config(); cfg=json.loads(Path(env['MOCK_CONFIG_JSON']).read_text())
        cfg['main']['mwan3']='0'; Path(env['MOCK_CONFIG_JSON']).write_text(json.dumps(cfg))
        wrapper=self.temp/'unused-wrapper'; wrapper.write_text('fixture: must not be loaded')
        env.update(MOCK_CURL_VERSION='8.8.0', BJUT_MWAN_WRAPPER=str(wrapper))
        ticket,owner=self.billing('billing_success',env)
        value=self.billing_poll(ticket,owner,env)
        self.assertEqual(value['result']['state'],'error',value)
        self.assertNotIn('URL ',self.requests())

    def test_billing_captcha_resumes_same_session_and_other_owner_cannot_read_it(self):
        env=self.config();ticket,owner=self.billing('billing_captcha',env)
        value=self.billing_poll(ticket,owner,env)
        self.assertEqual(value['result']['state'],'captcha')
        self.assertTrue(value['result']['image'].startswith('data:image/png;base64,'))
        denied=self.rpc('billing_poll',{'ticket':ticket,'owner':'2'*32},**env)
        self.assertEqual(json.loads(denied.stdout)['state'],'error')
        resumed=self.rpc('billing_captcha',{'ticket':ticket,'owner':owner,'code':'AB12','refresh':False},
                         BJUT_BILLING=CORE/'files/usr/libexec/bjut-billing',BJUT_HTML=self.html,
                         MOCK_SCENARIO='billing_captcha',**env)
        self.assertEqual(json.loads(resumed.stdout)['state'],'loading')
        ready=self.billing_poll(ticket,owner,env)
        self.assertEqual(ready['result']['state'],'ready',ready)

    def test_mwan_removes_only_owned_rules_after_uplink_is_removed(self):
        env=self.config(); directory=Path(env['BJUT_CONFIG_DIR']); mwan=directory/'mwan3'
        mwan.write_text(json.dumps({'user_rule':{'.type':'rule','use_policy':'balanced'},'old_bjut':{'.type':'rule','bjut_managed':'1','bjut_uplink':'removed','src_ip':'10.126.99.1/32'}}))
        result=self.run_service(scenario='multi_mapped',BJUT_MWAN_CONFIG=mwan,**env)
        self.assertEqual(result.returncode,0,result.stderr)
        stored=json.loads(mwan.read_text())
        self.assertNotIn('old_bjut',stored)
        self.assertEqual(stored['user_rule']['use_policy'],'balanced')

    def test_same_physical_source_cannot_run_two_auth_requests_in_parallel(self):
        env=self.config()
        network=json.loads(Path(env['MOCK_NETWORK_JSON']).read_text())
        network['wan24']=network['wan14']; Path(env['MOCK_NETWORK_JSON']).write_text(json.dumps(network))
        self.run_service(scenario='multi_mapped',MOCK_PROBE_DELAY='0.3',**env)
        status=self.status()['uplinks']
        self.assertEqual(sum(item['state']=='busy' for item in status),1)
        submissions=[line for line in self.requests().splitlines() if line.startswith('URL ') and '/eportal/portal/login?' in line]
        self.assertEqual(len(submissions),1)

    def test_old_curl_without_mwan_wrapper_fails_before_submitting_credentials(self):
        self.run_service(scenario='type1_success',MOCK_CURL_VERSION='8.8.0',BJUT_MWAN_WRAPPER='/nonexistent/wrapper.so')
        self.assertEqual(self.status()['state'],'blocked')
        self.assertNotIn('URL ',self.requests())

    def test_bound_policy_routes_use_each_family_gateway_without_changing_main_routes(self):
        env=self.config()
        network=json.loads(Path(env['MOCK_NETWORK_JSON']).read_text())
        network['wan14']['route']=[{'target':'0.0.0.0','mask':0,'nexthop':'10.126.19.254'}]
        network['wan16']['route']=[{'target':'::','mask':0,'nexthop':'fe80::1'}]
        network['wan24']['route']=[{'target':'0.0.0.0','mask':0,'nexthop':'10.126.20.254'}]
        Path(env['MOCK_NETWORK_JSON']).write_text(json.dumps(network))
        trace=self.temp/'routes.log'
        result=self.run_service(scenario='multi_mapped',MOCK_ROUTE_TRACE=trace,**env)
        self.assertEqual(result.returncode,0,result.stderr)
        status=self.status()['uplinks']
        self.assertEqual(status[0]['route4'],'managed'); self.assertEqual(status[0]['route6'],'managed')
        commands=trace.read_text()
        self.assertIn('default via 10.126.19.254 dev lan3 src 10.126.19.139',commands)
        self.assertIn('default via fe80::1 dev lan6 src 2001:da8:216::123',commands)
        self.assertIn('from 10.126.20.139/32 oif lan4',commands)
        self.assertNotIn('table main',commands)
        self.assertNotIn('route flush table main',commands)

    def test_bound_routes_preserve_onlink_gateways_and_remain_stable_across_checks(self):
        env=self.config()
        network=json.loads(Path(env['MOCK_NETWORK_JSON']).read_text())
        network['wan14']['route']=[{'target':'0.0.0.0','mask':0,'nexthop':'10.126.19.254'}]
        Path(env['MOCK_NETWORK_JSON']).write_text(json.dumps(network))
        trace=self.temp/'routes.log'
        connected=json.dumps({'-4':['10.126.0.0/16 dev lan3 proto kernel scope link',
                                    '172.21.0.0/16 dev lan3 proto static scope link',
                                    '192.168.99.0/24 dev lan4 proto kernel scope link']})
        options=dict(scenario='multi_mapped',MOCK_ROUTE_TRACE=trace,MOCK_CONNECTED_ROUTES=connected,**env)
        first=self.run_service(**options)
        self.assertEqual(first.returncode,0,first.stderr)
        before=trace.read_text().splitlines()
        self.assertTrue(any('route replace 172.21.0.0/16 dev lan3 scope link' in line for line in before))
        self.assertFalse(any('route replace 192.168.99.0/24 dev lan3' in line for line in before))
        second=self.run_service(command='once',**options)
        self.assertEqual(second.returncode,0,second.stderr)
        later=trace.read_text().splitlines()[len(before):]
        self.assertFalse(any('route replace' in line or 'rule add' in line or 'route flush' in line for line in later),later)
        # A removed netifd default must not be rediscovered from our own table.
        network['wan14']['route']=[]
        Path(env['MOCK_NETWORK_JSON']).write_text(json.dumps(network))
        third=self.run_service(command='once',**options)
        self.assertEqual(third.returncode,0,third.stderr)
        self.assertEqual(self.status()['uplinks'][0]['route4'],'missing_default')
        self.assertFalse((self.state/'routes-dorm_a-4').exists())

    def test_device_override_cannot_use_an_address_owned_by_another_device(self):
        env=self.config(); cfg=json.loads(Path(env['MOCK_CONFIG_JSON']).read_text())
        cfg['dorm_a']['device']='lan4'; cfg['dorm_b']['enabled']='0'
        Path(env['MOCK_CONFIG_JSON']).write_text(json.dumps(cfg))
        self.run_service(scenario='multi_mapped',**env)
        self.assertEqual(self.status()['uplinks'][0]['state'],'waiting_interface')
        self.assertNotIn('URL ',self.requests())

    def test_explicit_manual_login_can_use_disabled_account_even_when_public_probe_is_online(self):
        env=self.config(); cfg=json.loads(Path(env['MOCK_CONFIG_JSON']).read_text())
        cfg['account2']['enabled']='0'; Path(env['MOCK_CONFIG_JSON']).write_text(json.dumps(cfg))
        (self.state/'login_succeeded.lan4').touch()
        result=subprocess.run(['sh',str(base.SCRIPT),'manual','dorm_b','account2'],
                              env=self.environment('multi_mapped',**env),capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('user_account=25000002%40campus',self.requests())
        item=json.loads((self.state/'uplink-dorm_b.json').read_text())
        self.assertEqual(item['account'],'25***02')

    def test_already_online_response_does_not_rotate_or_claim_selected_account(self):
        self.run_service(scenario='type1_already_online',MOCK_LOGIN_TYPE='type1',MOCK_ACCOUNT_COUNT='2',MOCK_SSID='bjut_sushe')
        self.assertEqual(self.status()['state'],'request_failed')
        self.assertEqual(self.status()['session'],'offline')
        self.assertEqual(self.status()['account'],'')
        requests=[line for line in self.requests().splitlines() if line.startswith('URL ') and '/eportal/portal/login?' in line]
        self.assertEqual(len(requests),1)

    def test_accepted_login_with_confirmed_session_does_not_invent_working_internet(self):
        self.run_service(scenario='type1_success',MOCK_LOGIN_TYPE='type1',MOCK_PUBLIC_FAILURES='1',MOCK_SSID='bjut_sushe')
        item=self.status()
        self.assertEqual(item['state'],'authenticated_limited')
        self.assertEqual(item['session'],'online')
        self.assertEqual(item['internet4'],'unreachable')
        self.assertEqual(item['account'],'25***01')

    def test_lgn_landing_identifies_unauthenticated_gateway_without_user_info(self):
        result=self.run_service(scenario='type3_success',MOCK_DEVICE='eth0',MOCK_TRANSPORT_ACTUAL='ethernet',MOCK_LOGIN_TYPE='auto',MOCK_IPV4='172.26.33.104')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.status()['protocol'],'type3')
        self.assertEqual(self.status()['session'],'online')
        self.assertIn('URL https://lgn.bjut.edu.cn/',self.requests())
        self.assertIn('/eportal/portal/login?',self.requests())

    def html_run(self, operation, html, extra=None):
        return subprocess.run([str(self.html), operation, *([extra] if extra else [])], input=html, text=True, capture_output=True)

    def test_html_parser_extracts_metrics_without_evaluating_or_returning_password(self):
        html = '''<script>window.user=(function(x){return x})({"userName":"25000001","leftMoney":42,"userPassword":"do not publish"});</script>
        <label>状　　态：</label><div><span class="label-success">正常</span></div>'''
        user = self.html_run('user-json', html)
        self.assertEqual(json.loads(user.stdout)['leftMoney'], 42)
        self.assertEqual(self.html_run('status', html).stdout.strip(), '正常')
        self.assertNotEqual(self.html_run('user-json', 'window.user=function(){})').returncode, 0)

    def test_html_form_entities_and_captcha_visibility(self):
        html = '''<form method='post' action='/Self/login/verify;jsessionid=abc'><input value="1234" name="checkcode"><div id='randomDiv' class='form-group hide'></div></form>'''
        self.assertEqual(self.html_run('input', html, 'checkcode').stdout, '1234')
        self.assertEqual(self.html_run('action', html).stdout, '/Self/login/verify;jsessionid=abc')
        self.assertEqual(self.html_run('captcha', html).stdout, '0')
        self.assertEqual(self.html_run('captcha', html.replace(' hide','')).stdout, '1')


if __name__ == '__main__':
    unittest.main()
