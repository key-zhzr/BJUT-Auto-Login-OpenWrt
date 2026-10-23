#!/usr/bin/env python3
"""Offline contracts for coordinated actions, billing parity and maintenance."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import unittest
import test_multi_uplink as multi
import test_openwrt_port as base


class CollaborationTests(unittest.TestCase):
    setUpClass=classmethod(multi.MultiUplinkTests.setUpClass.__func__)
    tearDownClass=classmethod(multi.MultiUplinkTests.tearDownClass.__func__)
    setUp=multi.MultiUplinkTests.setUp
    tearDown=multi.MultiUplinkTests.tearDown
    environment=multi.MultiUplinkTests.environment
    config=multi.MultiUplinkTests.config
    rpc=multi.MultiUplinkTests.rpc

    def shell(self,script,**overrides):
        env=self.environment('online',BJUT_SELF=str(base.SCRIPT),BJUT_SOURCE_ONLY='1',BJUT_HTML=str(self.html),BJUT_DATA_DIR=str(self.temp/'private'),**overrides)
        return subprocess.run(['sh','-c','. "$BJUT_SELF";'+script],env=env,capture_output=True,text=True,timeout=35)

    def overview(self,html):
        work=self.temp/'work';job=self.temp/'job';work.mkdir(exist_ok=True);job.mkdir(exist_ok=True)
        (work/'billing-body').write_text(html)
        result=self.shell('''. "$LIB_DIR/billing.sh"; WORK_DIR="$TEST_WORK"; BILLING_JOB="$TEST_JOB"; BILLING_ACCOUNT=25000001
UPLINK_ID=dorm_a; billing_request(){ return 1; };billing_publish_overview;cat "$BILLING_JOB/result.json"''',TEST_WORK=str(work),TEST_JOB=str(job))
        self.assertEqual(result.returncode,0,result.stderr)
        return json.loads(result.stdout)

    def test_dashboard_values_follow_app_rendered_metric_precedence_and_units(self):
        html='''<script>(function(user){window.user=user;})({"userName":"25000001","leftMoney":999,"leftFlow":999999,"userPassword":"fixture-private","serviceDefault":{"defaultName":"测试套餐","extend":"套餐说明"}});</script>
<dl><dt>12.3456 <small>元</small></dt><dd>账户余额</dd></dl>
<dl><dt>3122 <small>MB</small></dt><dd>可用流量</dd></dl>
<dl><dt>1024 <small>MB</small></dt><dd>已用流量</dd></dl>
<label>其他状态：</label><div>错误</div><label>状　态：</label><div><span>正常</span></div>
<label>计费周期：</label>2026-07-01 至 2026-07-31'''
        item=self.overview(html)
        self.assertEqual(item['balanceText'],'12.3456 元')
        self.assertEqual(item['balance'],'12.3456')
        self.assertEqual(item['remainingFlowText'],'3.05 GB')
        self.assertEqual(float(item['remainingFlow']),3122)
        self.assertEqual(item['usedFlowText'],'1024 MB')
        self.assertEqual(item['accountStatus'],'正常')
        self.assertEqual(item['billingCycle'],'2026-07-01 至 2026-07-31')
        self.assertNotIn('fixture-private',json.dumps(item))
        self.assertNotIn('userPassword',json.dumps(item))

    def test_unknown_and_unlimited_flow_are_not_zero(self):
        for raw,expected in [('-1','无限'),('15250.454','14.89 GB')]:
            item=self.overview('<script>(function(user){window.user=user;})({"userName":"25000001","leftFlow":'+raw+'});</script>')
            self.assertEqual(item['remainingFlowText'],expected)
        item=self.overview('<script>(function(user){window.user=user;})({"userName":"25000001"});</script>')
        self.assertEqual(item['remainingFlow'],'')
        self.assertEqual(item['remainingFlowText'],'--')
        self.assertEqual(item['totalFlow'],'')

    def test_case_insensitive_and_nested_json_records_match_app(self):
        file=self.temp/'nested.json';out=self.temp/'normalized.json'
        file.write_text(json.dumps(json.dumps({'rows':[{'MACADDRESS':'aabbccddeeff','COSTMONEY':0}],'total':'1'})))
        result=self.shell('''. "$LIB_DIR/billing.sh";billing_normalize_json "$TEST_INPUT" "$TEST_OUTPUT" || exit 1
row="$(json_file_value "$TEST_OUTPUT" '@.rows[0]')";billing_row_value "$row" costMoney 0;printf '\\n';billing_row_value "$row" macAddress 1 | { read -r value; billing_format_mac "$value"; }''',TEST_INPUT=str(file),TEST_OUTPUT=str(out))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.split(),['0','AA-BB-CC-DD-EE-FF'])

    def test_duplicate_actions_reuse_a_task_and_finished_task_survives_refresh(self):
        env=self.config()
        shim=self.temp/'worker.sh'
        shim.write_text('''#!/bin/sh
if [ "$1" = manual ];then exit 0;fi
. "$ORIGINAL_SELF"
''');shim.chmod(0o755)
        environment=self.environment('online',BJUT_SELF=str(shim),ORIGINAL_SELF=str(base.SCRIPT),**env)
        def call():return subprocess.run(['sh',str(multi.RPC),'call','login'],input=json.dumps({'uplink':'dorm_a','account':'account1'}),env=environment,capture_output=True,text=True)
        a=call();b=call()
        first=json.loads(a.stdout);second=json.loads(b.stdout)
        self.assertEqual(first['operationId'],second['operationId'])
        result=self.shell('load_configuration;select_uplink dorm_a;OPERATION_ID="$(json_file_value "$STATE_DIR/operation-dorm_a.json" \'@.id\')";operation_update running 核对接口;operation_complete online 登录完成;operation_status dorm_a',**env)
        self.assertEqual(result.returncode,0,result.stderr)
        task=json.loads(result.stdout);self.assertEqual(task['state'],'succeeded');self.assertEqual(task['id'],first['operationId'])

    def test_account_limit_counts_online_sources_and_pending_reservations(self):
        env=self.config();file=Path(env['MOCK_CONFIG_JSON']);config=json.loads(file.read_text());config['account1']['max_sessions']='1';file.write_text(json.dumps(config))
        (self.state/'uplink-dorm_b.json').write_text(json.dumps({'account':'25000001','state':'online','device':'lan4','ipv4':'10.126.20.139'}))
        result=self.shell('load_configuration;select_uplink dorm_a;account_reserve account1',**env)
        self.assertNotEqual(result.returncode,0)
        (self.state/'uplink-dorm_b.json').unlink()
        result=self.shell('load_configuration;select_uplink dorm_a;account_reserve account1',**env)
        self.assertEqual(result.returncode,0,result.stderr)
        result=self.shell('load_configuration;select_uplink dorm_b;account_reserve account1',**env)
        self.assertNotEqual(result.returncode,0)

    def test_maintenance_checks_architecture_hash_and_fixed_download_origin(self):
        directory=self.temp/'packages';directory.mkdir()
        manifest={'target':'mediatek/filogic','arch':'aarch64_cortex-a53','format':'apk','files':[]}
        for package in ('bjut-autologin','luci-app-bjut-autologin'):
            data=(package+' fixture').encode();(directory/(package+'.apk')).write_bytes(data)
            manifest['files'].append({'package':package,'sha256':hashlib.sha256(data).hexdigest()})
        (directory/'manifest.json').write_text(json.dumps(manifest))
        script='MAINT_TARGET=mediatek/filogic;MAINT_ARCH=aarch64_cortex-a53;MAINT_FORMAT=apk;maintenance_verify_pair "$TEST_DIRECTORY"'
        self.assertEqual(self.shell(script,TEST_DIRECTORY=str(directory)).returncode,0)
        (directory/'bjut-autologin.apk').write_bytes(b'tampered')
        self.assertNotEqual(self.shell(script,TEST_DIRECTORY=str(directory)).returncode,0)
        self.assertNotEqual(self.shell('maintenance_fetch https://untrusted.invalid/anything "$STATE_DIR/file"').returncode,0)
        self.assertFalse((self.state/'file').exists())

    def test_backup_stays_private_and_info_does_not_return_credentials(self):
        env=self.config();original=Path(env['MOCK_CONFIG_JSON']).read_bytes()
        result=self.shell('''load_configuration;. "$JSHN_SH"
maintenance_platform(){ MAINT_TARGET=mediatek/filogic;MAINT_ARCH=aarch64_cortex-a53;MAINT_FORMAT=apk;MAINT_INSTALLED=0.1.6-r13; }
maintenance_platform;maintenance_backup || exit 1;maintenance_info''',**env)
        self.assertEqual(result.returncode,0,result.stderr)
        info=json.loads(result.stdout);self.assertEqual(len(info['backups']),1)
        self.assertNotIn('fixture password',result.stdout)
        path=self.temp/'private/maintenance'/info['backups'][0]['id']/'config'
        self.assertEqual(path.read_bytes(),original);self.assertEqual(path.stat().st_mode&0o777,0o600)

    def test_interrupted_maintenance_and_expired_actions_do_not_restart_work(self):
        ticket='a'*32;directory=self.state/'maintenance'/ticket;directory.mkdir(parents=True)
        (directory/'created').write_text(str(int(time.time())-20));(directory/'lock').mkdir()
        result=self.rpc('maintenance_poll',{'ticket':ticket},**self.config())
        self.assertEqual(json.loads(result.stdout)['state'],'error');self.assertFalse((directory/'lock').exists())
        (self.state/'operation-dorm_a.json').write_text(json.dumps({'id':'b'*32,'state':'queued','deadline':1,'action':'login','account':'account1'}))
        result=self.shell('operation_status dorm_a')
        self.assertEqual(json.loads(result.stdout)['state'],'timeout')
        self.assertFalse((self.state/'manual-dorm_a').exists())

    def test_online_sessions_reject_partial_invalid_lists_and_accept_encoded_null(self):
        work=self.temp/'online-work';job=self.temp/'online-job';work.mkdir();job.mkdir()
        script='. "$LIB_DIR/billing.sh";WORK_DIR="$TEST_WORK";BILLING_JOB="$TEST_JOB";billing_capture_online'
        for payload,valid in [('"null"',True),(json.dumps(json.dumps([{'sessionId':'private','ip':'10.0.0.1'}])),True),('[{"sessionId":"first"},{"ip":"10.0.0.2"}]',False),('{"error":"expired"}',False)]:
            work.mkdir(exist_ok=True)
            (work/'billing-body').write_text(payload)
            result=self.shell(script,TEST_WORK=str(work),TEST_JOB=str(job))
            self.assertEqual(result.returncode==0,valid,(payload,result.stderr))
            self.assertEqual((job/'online.json').exists(),valid)

    def test_billing_background_preserves_last_good_result_and_cancels_recovered_alert(self):
        env=self.config();worker=self.temp/'billing-worker.sh'
        worker.write_text('''#!/bin/sh
if [ "$TEST_BILLING_MODE" = fail ];then
 printf '%s' '{"state":"error","message":"需要核对验证码"}' >"$BJUT_STATE_DIR/billing/$1/result.json"
else
 printf '%s' '{"state":"ready","account":"25000001","balance":"20","remainingFlow":"10000","balanceText":"20 元","remainingFlowText":"9.77 GB","updatedAt":1}' >"$BJUT_STATE_DIR/billing/$1/result.json"
fi
''');worker.chmod(0o755)
        # Keep just one query, then simulate a later failure for the same account.
        config=Path(env['MOCK_CONFIG_JSON']);data=json.loads(config.read_text());data['account2']['enabled']='0';config.write_text(json.dumps(data))
        key=hashlib.sha256(b'25000001').hexdigest();pending=self.state/'pushplus'/('.billing-'+key);pending.mkdir(parents=True)
        (pending/'pending.json').write_text('{"sequence":1}');(pending/'state.json').write_text('{"sequence":1}')
        script='load_configuration;CFG_BILLING_ALERTS=1;CFG_BALANCE_THRESHOLD=5;CFG_FLOW_THRESHOLD=5;billing_monitor_run;billing_cached'
        result=self.shell(script,BJUT_BILLING=str(worker),TEST_BILLING_MODE='ready',**env)
        self.assertEqual(result.returncode,0,result.stderr);item=json.loads(result.stdout)['items'][0]
        self.assertEqual(item['balance'],'20');self.assertFalse((pending/'pending.json').exists())
        result=self.shell(script,BJUT_BILLING=str(worker),TEST_BILLING_MODE='fail',**env)
        self.assertEqual(result.returncode,0,result.stderr);item=json.loads(result.stdout)['items'][0]
        self.assertEqual(item['balance'],'20');self.assertEqual(item['backgroundState'],'error')
        self.assertNotIn('fixture password',result.stdout)

    def test_summary_decimal_sums_require_every_nonempty_window(self):
        work=self.temp/'sums';work.mkdir();source=work/'records.json'
        source.write_text(json.dumps({'summary':{'FLOW':'0.1','COU':'1','PRIVATE':'hidden'}}))
        script='''. "$LIB_DIR/billing.sh";WORK_DIR="$TEST_WORK";RECORD_SOURCE="$TEST_SOURCE";BILLING_RECORD_KIND=usage;RECORD_COUNT=1
billing_summary_collect;billing_summary_collect;cat "$WORK_DIR/summary-FLOW"
printf '%s' '{"rows":[{}]}' >"$RECORD_SOURCE";billing_summary_collect
[ -f "$WORK_DIR/summary-FLOW-missing" ]'''
        result=self.shell(script,TEST_WORK=str(work),TEST_SOURCE=str(source))
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout,'0.2')

    def test_package_update_never_offers_same_or_older_versions_as_upgrade(self):
        manifest=self.temp/'manifest.json'
        for fmt,installed,name,newer in [
            ('apk','0.1.6-r13','openwrt-mediatek-filogic-25.12.5-apk__bjut-autologin-0.1.6-r14.apk',True),
            ('apk','0.1.6-r14','openwrt-mediatek-filogic-25.12.5-apk__bjut-autologin-0.1.6-r13.apk',False),
            ('ipk','0.1.6-14','openwrt-mediatek-filogic-24.10.8-ipk__bjut-autologin_0.1.6-14_aarch64_cortex-a53.ipk',False),
            ('ipk','0.1.6-14','openwrt-mediatek-filogic-24.10.8-ipk__bjut-autologin_0.1.7-1_aarch64_cortex-a53.ipk',True),
        ]:
            manifest.write_text(json.dumps({'files':[{'package':'bjut-autologin','name':name}]}))
            result=self.shell('MAINT_FORMAT="$TEST_FORMAT";MAINT_INSTALLED="$TEST_INSTALLED";maintenance_is_newer "$TEST_MANIFEST"',TEST_FORMAT=fmt,TEST_INSTALLED=installed,TEST_MANIFEST=str(manifest))
            self.assertEqual(result.returncode==0,newer,(name,result.stderr))

    def test_standalone_backup_worker_publishes_terminal_result(self):
        env=self.config();ticket='c'*32;job=self.state/'maintenance'/ticket;job.mkdir(parents=True)
        (job/'request.json').write_text('{"action":"backup"}')
        release=self.temp/'release';release.write_text("DISTRIB_ARCH='aarch64_cortex-a53'\n")
        ubus=self.temp/'board.sh';ubus.write_text('#!/bin/sh\nprintf \'%s\' \'{"release":{"target":"mediatek/filogic"}}\'\n');ubus.chmod(0o755)
        result=subprocess.run(['sh',str(base.CORE/'files/usr/libexec/bjut-maintenance'),ticket],env=self.environment('online',BJUT_SELF=str(base.SCRIPT),BJUT_UBUS=str(ubus),BJUT_RELEASE_FILE=str(release),BJUT_DATA_DIR=str(self.temp/'private'),**env),capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr)
        result=json.loads((job/'result.json').read_text());self.assertEqual(result['state'],'ready');self.assertEqual(result['message'],'路由配置已备份')
        self.assertTrue((self.temp/'private/maintenance'/result['backup']/'config').exists())


if __name__=='__main__':unittest.main()
