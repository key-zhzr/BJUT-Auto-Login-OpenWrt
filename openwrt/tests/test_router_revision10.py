import json
import os
from pathlib import Path
import subprocess
import time
import unittest
import test_multi_uplink as multi
CORE=multi.CORE
import test_openwrt_port as base


class RouterRevision10Tests(unittest.TestCase):
    setUpClass = classmethod(multi.MultiUplinkTests.setUpClass.__func__)
    tearDownClass = classmethod(multi.MultiUplinkTests.tearDownClass.__func__)
    setUp = multi.MultiUplinkTests.setUp
    tearDown = multi.MultiUplinkTests.tearDown
    environment = multi.MultiUplinkTests.environment
    config = multi.MultiUplinkTests.config
    rpc = multi.MultiUplinkTests.rpc
    billing = multi.MultiUplinkTests.billing
    billing_poll = multi.MultiUplinkTests.billing_poll
    requests = multi.MultiUplinkTests.requests

    def worker(self, method, args, env, scenario='billing_success'):
        response=self.rpc(method,args,MOCK_SCENARIO=scenario,BJUT_HTML=self.html,
                          BJUT_BILLING=CORE/'files/usr/libexec/bjut-billing',**env)
        self.assertEqual(response.returncode,0,response.stderr)
        data=json.loads(response.stdout)
        self.assertIn('ticket',data,data)
        return self.billing_poll(data['ticket'],'1'*32,env),data['ticket']

    def test_billing_services_devices_security_and_history_are_scoped(self):
        env=self.config()
        for module in ['services','devices','security','history']:
            value,ticket=self.worker('billing_details',{'uplink':'dorm_a','account':'account1','owner':'1'*32,'module':module},env)
            result=value['result'];self.assertEqual(result['state'],'ready',value)
            self.assertEqual(result['account'],'25000001');self.assertEqual(result['module'],module)
            self.assertNotIn('userPassword',json.dumps(value));self.assertNotIn('fixture-session',json.dumps(value))
            if module=='services':
                self.assertEqual(result['canStop'],1);self.assertEqual(result['canReopen'],0)
                self.assertEqual(result['packages'][0]['id'],'2');self.assertEqual(result['installmentFlag'],'100')
            if module=='security':
                self.assertEqual(len(result['questions']),3);self.assertEqual(result['FLDMINLENGTH'],8)
            if module=='devices':
                self.assertEqual(result['mauth'],'1');self.assertEqual(value['sessions'][0]['sessionIndex'],0)
                self.assertEqual(result['macs']['rows'][0][1],'aabbccddeeff')
            if module=='history':
                self.assertEqual(len(result['history']['rows']),1)
                self.assertEqual(result['history']['columns'][5:9],['durationMinutes','flowMb','billingMode','amount'])
                self.assertEqual(result['history']['rows'][0][5:9],['60','42','3','0'])
            forbidden=self.rpc('billing_poll',{'ticket':ticket,'owner':'2'*32},**env)
            self.assertEqual(json.loads(forbidden.stdout)['state'],'error')

    def test_billing_action_rechecks_account_and_never_accepts_an_endpoint(self):
        env=self.config();ticket,owner=self.billing('billing_sso',env,account='current')
        self.assertEqual(self.billing_poll(ticket,owner,env)['result']['account'],'25000099')
        value,_=self.worker('billing_action',{'ticket':ticket,'owner':owner,'operation':'stopNow','payload':'{}'},
                            dict(env,MOCK_SSO_USER='25000098'),scenario='billing_sso')
        self.assertEqual(value['result']['state'],'error');self.assertNotIn('/Self/service/stop',self.requests())
        for operation,payload in [('stopNow','{"path":"https://foreign.test"}'),('arbitrary','{}'),('setConsumeLimit','{"consumeLimit":1}')]:
            response=self.rpc('billing_action',{'ticket':ticket,'owner':owner,'operation':operation,'payload':payload},**env)
            self.assertEqual(json.loads(response.stdout)['state'],'error')

    def test_named_billing_action_and_session_disconnect(self):
        env=self.config();ticket,owner=self.billing('billing_success',env)
        self.billing_poll(ticket,owner,env)
        for operation,payload in [('stopNow',{}),('schedulePackage',{'packageId':'2'}),('setConsumeLimit',{'consumeLimit':'150'}),('disconnectSession',{'sessionIndex':'0'})]:
            value,_=self.worker('billing_action',{'ticket':ticket,'owner':owner,'operation':operation,'payload':json.dumps(payload)},env)
            self.assertEqual(value['result']['state'],'ready',value)
        self.assertIn('/Self/dashboard/tooffline?sessionid=fixture-session',self.requests())
        value,_=self.worker('billing_action',{'ticket':ticket,'owner':owner,'operation':'schedulePackage','payload':'{"packageId":"foreign"}'},env)
        self.assertEqual(value['result']['state'],'error')

    def test_ambiguous_billing_action_is_not_retried_after_reauthentication(self):
        env=self.config();ticket,owner=self.billing('billing_sso',env,account='current')
        self.assertEqual(self.billing_poll(ticket,owner,env)['result']['state'],'ready')
        value,_=self.worker('billing_action',{'ticket':ticket,'owner':owner,'operation':'stopNow','payload':'{}'},
                            dict(env,MOCK_ACTION_TIMEOUT='1'),scenario='billing_sso')
        self.assertEqual(value['result']['state'],'error',value)
        self.assertEqual(self.requests().count('URL https://jfself.bjut.edu.cn/Self/service/stop\n'),1)

    def test_a_billing_worker_that_never_started_does_not_leave_a_spinner(self):
        env=self.config();worker=self.temp/'empty-worker.sh';worker.write_text('exit 0\n')
        response=self.rpc('billing_start',{'uplink':'dorm_a','account':'account1','owner':'1'*32},
                          BJUT_BILLING=str(worker),**env)
        ticket=json.loads(response.stdout)['ticket'];job=self.state/'billing'/ticket
        (job/'launched').write_text(str(int(time.time())-15))
        value=self.billing_poll(ticket,'1'*32,env,attempts=2)
        self.assertEqual(value['result']['state'],'error',value)
        self.assertIn('已中断',value['result']['message'])

    def test_info_log_destination_rotation_and_public_link_are_owned(self):
        env=self.config();config=Path(env['MOCK_CONFIG_JSON']);data=json.loads(config.read_text())
        directory=self.state/'logs';web=self.temp/'web';private=self.temp/'private'
        data['main'].update(log_level='info',log_target='file',log_directory=str(directory),log_web='1',log_max_kb='64')
        config.write_text(json.dumps(data));environment=self.environment('type1_success',**env,BJUT_DATA_DIR=str(private),BJUT_WEB_ROOT=str(web))
        result=subprocess.run(['sh',str(base.SCRIPT),'manual','dorm_a'],env=environment,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        logfile=directory/'bjut-autologin.log';text=logfile.read_text();self.assertIn('开始检测',text);self.assertIn('检测完成',text);self.assertNotIn('first fixture password',text)
        self.assertTrue((web/'bjut-autologin.log').is_symlink());self.assertEqual((web/'bjut-autologin.log').resolve(),logfile.resolve())
        logfile.write_text('old log\n'*10000)
        logged=subprocess.run(['sh','-c','. "$BJUT_SELF";load_configuration;log_message info "rotation fixture"'],
                              env=dict(environment,BJUT_SOURCE_ONLY='1',BJUT_SELF=str(base.SCRIPT)),capture_output=True,text=True)
        self.assertEqual(logged.returncode,0,logged.stderr)
        self.assertIn('rotation fixture',logfile.read_text());self.assertTrue(Path(str(logfile)+'.1').stat().st_size>65536)
        for _ in range(2):
            setup=subprocess.run(['sh',str(base.SCRIPT),'setup'],env=environment,capture_output=True,text=True);self.assertEqual(setup.returncode,0,setup.stderr)
            marker=json.loads((web/'.well-known/bjut-autologin.json').read_text());self.assertRegex(marker['routerId'],r'^[a-f0-9]{32}$')
            if _==0:first=marker['routerId']
            else:self.assertEqual(first,marker['routerId'])
        data['main']['log_target']='system';config.write_text(json.dumps(data))
        subprocess.run(['sh',str(base.SCRIPT),'setup'],env=environment,check=True)
        self.assertFalse((web/'bjut-autologin.log').is_symlink());self.assertTrue(logfile.exists())
        (web/'bjut-autologin.log').write_text('unrelated file')
        subprocess.run(['sh',str(base.SCRIPT),'setup'],env=environment,check=True)
        self.assertEqual((web/'bjut-autologin.log').read_text(),'unrelated file')

    def test_logout_pauses_automatic_login_and_manual_login_resumes(self):
        env=self.config();environment=self.environment('type1_success',**env)
        def run(action,account=''):
            return subprocess.run(['sh',str(base.SCRIPT),action,'dorm_a',account],env=environment,capture_output=True,text=True)
        self.assertEqual(run('manual','account1').returncode,0)
        result=run('logout');self.assertEqual(result.returncode,0,result.stderr)
        status=json.loads((self.state/'uplink-dorm_a.json').read_text());self.assertEqual(status['state'],'logged_out')
        before=self.requests();self.assertEqual(run('once').returncode,0);self.assertEqual(before,self.requests())
        self.assertEqual(run('manual','account1').returncode,0)
        self.assertFalse((self.state/'paused-dorm_a').exists())

    def test_public_probes_return_first_success_without_waiting_for_other_targets(self):
        env=self.config();environment=self.environment('online',**env,MOCK_DELAY_CONFIGURED='2',MOCK_DELAY_USTC='.02',MOCK_DELAY_ALIDNS='2')
        script=r""". "$BJUT_SELF";load_configuration;select_uplink dorm_a;read_network_identity;prepare_work_dir;printf 'ready\n';online_check;rc=$?;cleanup_runtime;exit "$rc";"""
        environment.update(BJUT_SOURCE_ONLY='1',BJUT_SELF=str(base.SCRIPT))
        process=subprocess.Popen(['sh','-c',script],env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.assertEqual(process.stdout.readline().strip(),'ready');start=time.monotonic();stdout,stderr=process.communicate(timeout=10)
        self.assertEqual(process.returncode,0,stderr);self.assertLess(time.monotonic()-start,1.5)

    def test_route_lock_waits_for_its_owner_and_recovers_after_exit(self):
        environment=self.environment('online',BJUT_SOURCE_ONLY='1',BJUT_SELF=str(base.SCRIPT))
        lock=self.state/'route-lock.pid';entered=self.state/'route-entered'
        script=r''' . "$BJUT_SELF";. "$LIB_DIR/routing.sh"
ensure_family_route(){ printf 'entered\n' >>"$STATE_DIR/route-entered";ROUTE_RESULT=managed; }
printf 'ready\n';ensure_uplink_routes || exit 1;printf '%s:%s' "$ROUTE4" "$ROUTE6"
'''
        holder=subprocess.Popen(['sh','-c','sleep 10'])
        lock.write_text(str(holder.pid))
        worker=subprocess.Popen(['sh','-c',script],env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            self.assertEqual(worker.stdout.readline().strip(),'ready')
            time.sleep(.2)
            self.assertFalse(entered.exists(),'a second uplink entered an owned route update')
            self.assertEqual(lock.read_text().strip(),str(holder.pid))
            holder.terminate();holder.wait(timeout=2)
            stdout,stderr=worker.communicate(timeout=6)
            self.assertEqual(worker.returncode,0,stderr);self.assertEqual(stdout,'managed:managed')
            self.assertFalse(lock.exists())
            lock.write_text('99999999')
            recovered=subprocess.run(['sh','-c',script],env=environment,capture_output=True,text=True,timeout=6)
            self.assertEqual(recovered.returncode,0,recovered.stderr)
            self.assertFalse(lock.exists())
        finally:
            for process in (holder,worker):
                if process.poll() is None:process.terminate()
                process.wait(timeout=3)

if __name__=='__main__':unittest.main()
