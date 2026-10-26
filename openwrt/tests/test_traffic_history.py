"""Billing units, persistent deltas, and IPv6-only identity without a router."""
import json
import os
import signal
import time
import subprocess
import unittest
from pathlib import Path
import test_multi_uplink as multi
import test_openwrt_port as base

class TrafficTests(unittest.TestCase):
    setUpClass=classmethod(multi.MultiUplinkTests.setUpClass.__func__)
    tearDownClass=classmethod(multi.MultiUplinkTests.tearDownClass.__func__)
    setUp=multi.MultiUplinkTests.setUp
    tearDown=multi.MultiUplinkTests.tearDown
    environment=multi.MultiUplinkTests.environment
    def config(self):
        env=multi.MultiUplinkTests.config(self)
        path=Path(env['MOCK_CONFIG_JSON']);data=json.loads(path.read_text())
        data['main'].update(traffic_monitor='1',traffic_scope='all')
        path.write_text(json.dumps(data));return env

    def shell(self,script,**overrides):
        result=subprocess.run(['sh','-c',f'. "{base.SCRIPT}"; . "$LIB_DIR/billing.sh"; . "$JSHN_SH"; '+script],env=self.environment('type3_success',BJUT_SELF=base.SCRIPT,BJUT_SOURCE_ONLY='1',BJUT_TRAFFIC_HISTORY=self.temp/'persistent.tsv',BJUT_TRAFFIC_CURVES=self.temp/'curves.tsv',CFG_TRAFFIC_SCOPE='all',**overrides),capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        return result.stdout

    def test_units_history_gaps_resets_and_multi_account_json(self):
        env=self.config();file=self.temp/'online.json'
        row={'sessionId':'private-session','loginTime':'2026-10-25 12:00:00','ip':'192.0.2.3','mac':'aabbccddeeff','downFlow':10240,'upFlow':2048}
        file.write_text(json.dumps([row]))
        data=json.loads(self.shell('traffic_rows "$ONLINE"',ONLINE=file,**env))
        self.assertEqual(data[0]['usedFlowMb'],'10.000')
        self.assertNotIn('private-session',json.dumps(data))
        script='load_configuration; for account in 25000001 25000002; do key=$(printf "%s" "$account" | sha256sum | awk \'{print $1}\'); traffic_history_record "$key" "$ONLINE" "$AT"; done; traffic_history_json'
        self.assertEqual(json.loads(self.shell(script,ONLINE=file,AT='1792886400',**env)),[])
        row['downFlow']=12288;file.write_text(json.dumps([row]))
        history=json.loads(self.shell(script,ONLINE=file,AT='1792886460',**env))
        self.assertEqual(len(history),2,history)
        self.assertEqual({r['account'] for r in history},{'25000001','25000002'})
        self.assertTrue(all(r['usedMb']==2 and r['sampledSeconds']==60 for r in history),history)
        row['downFlow']=1024;file.write_text(json.dumps([row]))
        history=json.loads(self.shell(script,ONLINE=file,AT='1792886520',**env))
        self.assertTrue(all(r['usedMb']==2 for r in history))
        row['downFlow']=102400;file.write_text(json.dumps([row]))
        history=json.loads(self.shell(script,ONLINE=file,AT='1792887000',**env))
        self.assertTrue(all(r['usedMb']==2 for r in history))
        self.assertTrue((self.temp/'persistent.tsv').exists())

    def test_shared_app_counter_corpus(self):
        source=Path(__file__).parent/'fixtures/billing-online.json'
        rows=json.loads(self.shell('traffic_rows "$ONLINE"',ONLINE=source))
        self.assertEqual([row['usedFlowMb'] for row in rows],['3.000','2.000'])
        self.assertNotIn('fixture-private',json.dumps(rows))

    def test_background_metrics_use_the_same_precedence_as_billing_overview(self):
        env=self.config()
        dashboard=self.temp/'dashboard.html'
        dashboard.write_text('<script>window.user=(function(x){return x})({"userName":"25000001","leftMoney":0,"leftFlow":0,"useFlag":1});</script><dl><dt>5.25 元</dt><dd>账户余额</dd></dl><dl><dt>1.5 GB</dt><dd>可用流量</dd></dl>')
        output=self.shell('load_configuration; ACCOUNT_SECTIONS=account1; traffic_collect; traffic_cached',MOCK_SCENARIO='billing_success',MOCK_BILLING_DASHBOARD=dashboard,BJUT_HTML=self.html,BJUT_BILLING=base.CORE/'files/usr/libexec/bjut-billing',**env)
        account=json.loads(output)['accounts'][0]
        self.assertEqual(float(account['remainingFlow']),1536)
        self.assertEqual(float(account['balance']),5.25)

    def test_sampler_wakes_at_the_earliest_account_deadline(self):
        env=self.config()
        script='''load_configuration
date() { if [ "$1" = +%s ]; then printf 1000; else command date "$@"; fi; }
mkdir -p "$STATE_DIR/traffic"
next=1010
for section in $ACCOUNT_SECTIONS; do
 config_get user "$section" username ''
 key=$(printf '%s' "$user" | sha256sum | awk '{print $1}')
 printf '%s' "$next" > "$STATE_DIR/traffic/$key-next"
 next=$((next+30))
done
traffic_collect
printf '%s' "$TRAFFIC_NEXT_AT"
'''
        self.assertEqual(self.shell(script,**env),'1010')

    def test_staggered_accounts_are_not_skipped_for_another_minute(self):
        env=self.config()
        worker=self.temp/'billing-worker.sh'
        worker.write_text('''mkdir -p "$BJUT_STATE_DIR/billing/$1"
printf '{"state":"ready"}' > "$BJUT_STATE_DIR/billing/$1/result.json"
printf '[]' > "$BJUT_STATE_DIR/billing/$1/online.json"
printf x >> "$BJUT_STATE_DIR/traffic-worker-calls"
''')
        script='''load_configuration
AT=1000
date() { if [ "$1" = +%s ]; then printf '%s' "$AT"; else command date "$@"; fi; }
mkdir -p "$STATE_DIR/traffic"
next=1000
for section in $ACCOUNT_SECTIONS; do
 config_get user "$section" username ''
 key=$(printf '%s' "$user" | sha256sum | awk '{print $1}')
 printf '%s' "$next" > "$STATE_DIR/traffic/$key-next"
 next=$((next+10))
done
for AT in 1000 1010 1060; do traffic_collect; printf '%s\\n' "$TRAFFIC_NEXT_AT"; done
wc -c < "$STATE_DIR/traffic-worker-calls"
'''
        output=self.shell(script,BJUT_BILLING=worker,**env).split()
        self.assertEqual(output,['1010','1060','1070','3'])

    def test_collection_is_opt_in_even_for_an_old_enabled_default(self):
        env=self.config();path=Path(env['MOCK_CONFIG_JSON']);data=json.loads(path.read_text())
        data['main'].pop('traffic_scope');path.write_text(json.dumps(data))
        report=json.loads(self.shell('load_configuration; traffic_collect; traffic_cached',**env))
        self.assertFalse(report['enabled']);self.assertEqual(report['scope'],'local');self.assertEqual(report['accounts'],[])
        self.assertFalse((self.state/'traffic').exists())

    def test_local_scope_matches_observed_uplinks_and_rolls_up_each_tier_once(self):
        env=self.config();file=self.temp/'local.json'
        rows=[{'sessionId':'one','loginTime':'first','ip':'10.126.19.139','mac':'aabbccddeeff','downFlow':10240,'upFlow':0},
              {'sessionId':'other','loginTime':'first','ip':'192.0.2.9','mac':'112233445566','downFlow':10240,'upFlow':0}]
        file.write_text(json.dumps(rows))
        script='load_configuration; CFG_TRAFFIC_SCOPE=local; traffic_identity_prepare; key=$(printf 25000001 | sha256sum | awk \'{print $1}\'); traffic_history_record "$key" "$ONLINE" "$AT"; traffic_series_json'
        self.assertEqual(json.loads(self.shell(script,ONLINE=file,AT='1792886400',**env))['buckets'],[])
        for row in rows:row['downFlow']+=2048
        file.write_text(json.dumps(rows))
        report=json.loads(self.shell(script,ONLINE=file,AT='1792886460',**env))
        self.assertEqual(len(report['channels']),1,report)
        self.assertTrue(report['channels'][0]['local']);self.assertEqual(report['channels'][0]['interfaceName'],'lan3')
        self.assertEqual({r[1] for r in report['buckets']},{60,3600,86400})
        self.assertTrue(all(r[3]==2 and r[4]==60 for r in report['buckets']),report)
        self.assertEqual(len(json.loads(self.shell('load_configuration;CFG_TRAFFIC_SCOPE=local;traffic_identity_prepare;traffic_rows "$ONLINE"',ONLINE=file,**env))),1)
        # Long gaps update baselines without inventing a burst in the chart.
        for row in rows:row['downFlow']+=10240
        file.write_text(json.dumps(rows))
        report=json.loads(self.shell(script,ONLINE=file,AT='1792887060',**env))
        self.assertTrue(all(r[3]==2 for r in report['buckets']),report)
        self.assertTrue((self.temp/'curves.tsv').exists())

    def test_ipv6_only_identity_lock_and_pd_are_observed_before_lgn(self):
        env=self.config();cfg=Path(env['MOCK_CONFIG_JSON']);data=json.loads(cfg.read_text());data['dorm_a']['login_type']='type3';cfg.write_text(json.dumps(data))
        net=Path(env['MOCK_NETWORK_JSON']);networks=json.loads(net.read_text());networks['wan14']['up']=False;networks['wan16']['ipv6-prefix']=[{'address':'2001:da8:216:abcd::','mask':64}];net.write_text(json.dumps(networks))
        output=self.shell('load_configuration;select_uplink dorm_a;read_network_identity || exit 10;acquire_source_lock || exit 11;printf "%s|%s|%s|%s" "$LOCAL_IPV4" "$LOCAL_IPV6" "$IPV6_PD" "$SOURCE_LOCK"',**env)
        self.assertTrue(output.startswith('|2001:da8:216::123|2001:da8:216:abcd::/64|'),output)
        networks['wan16']['ipv6-address'][0]['address']='2001:db8::123';net.write_text(json.dumps(networks))
        output=self.shell('load_configuration;select_uplink dorm_a;read_network_identity; code=$?; test "$code" = 2',**env)

    def test_capacity_defaults_to_three_and_requires_an_exact_verified_vip_plan(self):
        env=self.config()
        output=self.shell("load_configuration; account_effective_limit account1;printf '%s ' \"$ACCOUNT_LIMIT\";account_record_plan 25000001 'VIP套餐说明';account_effective_limit account1;printf '%s ' \"$ACCOUNT_LIMIT\";account_record_plan 25000001 'VIP套餐';account_effective_limit account1;printf '%s' \"$ACCOUNT_LIMIT\"",**env)
        self.assertEqual(output,'3 3 5')

    def test_observed_switch_wakes_only_the_new_account_and_keeps_other_baselines(self):
        env=self.config()
        code='''load_configuration;mkdir -p "$STATE_DIR/traffic" "$STATE_DIR/traffic-baselines";touch "$STATE_DIR/traffic-baselines/other"
UPLINK_ID=dorm_a;DEVICE=lan3
traffic_observe_account online 25000001
key=$(printf 25000002 | sha256sum | awk '{print $1}')
printf 9999999999 >"$STATE_DIR/traffic/$key-next"
traffic_observe_account online 25000002
cat "$STATE_DIR/traffic-switches.tsv"
test -f "$STATE_DIR/traffic/$key-wake" && test ! -f "$STATE_DIR/traffic/$key-next" && test -f "$STATE_DIR/traffic-baselines/other"
'''
        fields=self.shell(code,**env).strip().split('\t');self.assertEqual(fields[1:],['interface:lan3','lan3','25000001','25000002'])

    def test_router_retains_real_intervals_when_a_minute_has_no_endpoint(self):
        env=self.config();file=self.temp/'online.json';row={'sessionId':'one','loginTime':'first','ip':'192.0.2.3','mac':'aabbccddeeff','downFlow':10240,'upFlow':999999}
        file.write_text(json.dumps([row]));script='load_configuration;key=$(printf 25000001|sha256sum|awk \'{print $1}\');traffic_history_record "$key" "$ONLINE" "$AT";traffic_series_json'
        self.shell(script,ONLINE=file,AT='1792886459',**env)
        row['downFlow']+=1024;file.write_text(json.dumps([row]))
        report=json.loads(self.shell(script,ONLINE=file,AT='1792886520',**env));minute=next(r for r in report['buckets'] if r[1]==60)
        self.assertEqual(minute[3:],[1,61,1792886459,1792886520])

    def test_six_accounts_launch_in_one_cohort_despite_old_staggered_deadlines(self):
        env=self.config();cfg=Path(env['MOCK_CONFIG_JSON']);data=json.loads(cfg.read_text())
        for i in range(3,7):data[f'account{i}']={'.type':'account','enabled':'1','username':f'2500000{i}','password':'fixture password'}
        cfg.write_text(json.dumps(data));worker=self.temp/'sample-worker.sh'
        worker.write_text('''#!/bin/sh
if [ "$1" = --identities ];then sleep 12;exit 0;fi
printf "%s %s\n" "$1" "$(date +%s)" >>"$BJUT_STATE_DIR/cohort"
sleep 1
''');worker.chmod(0o755)
        path=self.temp/'state'/'traffic';path.mkdir(parents=True,exist_ok=True)
        (self.state/'traffic-identities.tsv').write_text('interface:lan3\tlan3\t-\t10.126.19.139\n')
        import hashlib
        for i in range(1,7):(path/(hashlib.sha256(f'2500000{i}'.encode()).hexdigest()+'-next')).write_text(str(int(time.time())+i*10))
        process=subprocess.Popen(['sh',str(base.CORE/'files/usr/libexec/bjut-traffic-monitor')],env=self.environment('online',BJUT_SELF=base.SCRIPT,BJUT_TRAFFIC_SAMPLE=worker,BJUT_TRAFFIC_HISTORY=self.temp/'persistent.tsv',BJUT_TRAFFIC_CURVES=self.temp/'curves.tsv',**env),stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        try:
            cutoff=time.monotonic()+20;file=self.temp/'state'/'cohort';rows=[]
            while time.monotonic()<cutoff:
                rows=file.read_text().splitlines() if file.exists() else []
                if len({row.split()[0] for row in rows})>=6:break
                time.sleep(.1)
            self.assertEqual(len({row.split()[0] for row in rows}),6,rows)
            self.assertLess(time.monotonic(),cutoff-12,'Slow identity refresh blocked account dispatch')
            times=[int(row.split()[1]) for row in rows[:6]]
            self.assertLessEqual(max(times)-min(times),5)
        finally:
            os.killpg(process.pid,signal.SIGTERM)
            try:process.communicate(timeout=5)
            except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.communicate()

    def test_failed_query_uplink_tries_another_upstream(self):
        env=self.config();worker=self.temp/'billing-worker.sh'
        worker.write_text('''#!/bin/sh
job="$BJUT_STATE_DIR/billing/$1"
case "$(cat "$job/request.json")" in
 *dorm_a*)printf '{"state":"error","message":"连接超时"}' >"$job/result.json";;
 *)printf '{"state":"ready"}' >"$job/result.json";printf '[]' >"$job/online.json";;
esac
printf x >>"$BJUT_STATE_DIR/attempts"
''')
        self.shell('load_configuration;ACCOUNT_SECTIONS=account1;traffic_collect;test "$(wc -c <"$STATE_DIR/attempts")" -eq 2',BJUT_BILLING=worker,**env)

    def test_online_counter_request_waits_for_the_shared_sample_boundary(self):
        env=self.config();target=int(time.time())+8
        code="""
load_configuration;ACCOUNT_SECTIONS=account1;traffic_collect
key=$(printf 25000001|sha256sum|awk '{print $1}')
cat "$STATE_DIR/traffic/$key-at"
"""
        at=int(self.shell(code,MOCK_SCENARIO='billing_success',BJUT_TRAFFIC_SAMPLE_AT=str(target),BJUT_HTML=self.html,BJUT_BILLING=base.CORE/'files/usr/libexec/bjut-billing',**env))
        self.assertGreaterEqual(at,target)
        self.assertLessEqual(at,target+2)

    def test_address_only_inventory_does_not_query_wireless_drivers(self):
        env=self.config()
        script='load_configuration;select_uplink dorm_a;read_network_identity;test -n "$LOCAL_IPV4";printf "%s" "$SSID"'
        self.assertEqual(self.shell(script,BJUT_NETWORK_ADDRESSES_ONLY='1',MOCK_UBUS_IWINFO='1',**env),'')
        self.assertNotEqual(self.shell(script,MOCK_UBUS_IWINFO='1',**env),'')

if __name__=='__main__':unittest.main()
