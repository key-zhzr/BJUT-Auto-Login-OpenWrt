"""Billing units, persistent deltas, and IPv6-only identity without a router."""
import json
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
    config=multi.MultiUplinkTests.config

    def shell(self,script,**overrides):
        result=subprocess.run(['sh','-c',f'. "{base.SCRIPT}"; . "$LIB_DIR/billing.sh"; . "$JSHN_SH"; '+script],env=self.environment('type3_success',BJUT_SELF=base.SCRIPT,BJUT_SOURCE_ONLY='1',BJUT_TRAFFIC_HISTORY=self.temp/'persistent.tsv',**overrides),capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        return result.stdout

    def test_units_history_gaps_resets_and_multi_account_json(self):
        env=self.config();file=self.temp/'online.json'
        row={'sessionId':'private-session','loginTime':'2026-10-25 12:00:00','ip':'192.0.2.3','mac':'aabbccddeeff','downFlow':10240,'upFlow':2048}
        file.write_text(json.dumps([row]))
        data=json.loads(self.shell('traffic_rows "$ONLINE"',ONLINE=file,**env))
        self.assertEqual(data[0]['usedFlowMb'],'12.000')
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
        self.assertEqual([row['usedFlowMb'] for row in rows],['4.000','3.000'])
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

    def test_ipv6_only_identity_lock_and_pd_are_observed_before_lgn(self):
        env=self.config();cfg=Path(env['MOCK_CONFIG_JSON']);data=json.loads(cfg.read_text());data['dorm_a']['login_type']='type3';cfg.write_text(json.dumps(data))
        net=Path(env['MOCK_NETWORK_JSON']);networks=json.loads(net.read_text());networks['wan14']['up']=False;networks['wan16']['ipv6-prefix']=[{'address':'2001:da8:216:abcd::','mask':64}];net.write_text(json.dumps(networks))
        output=self.shell('load_configuration;select_uplink dorm_a;read_network_identity || exit 10;acquire_source_lock || exit 11;printf "%s|%s|%s|%s" "$LOCAL_IPV4" "$LOCAL_IPV6" "$IPV6_PD" "$SOURCE_LOCK"',**env)
        self.assertTrue(output.startswith('|2001:da8:216::123|2001:da8:216:abcd::/64|'),output)
        networks['wan16']['ipv6-address'][0]['address']='2001:db8::123';net.write_text(json.dumps(networks))
        output=self.shell('load_configuration;select_uplink dorm_a;read_network_identity; code=$?; test "$code" = 2',**env)

if __name__=='__main__':unittest.main()
