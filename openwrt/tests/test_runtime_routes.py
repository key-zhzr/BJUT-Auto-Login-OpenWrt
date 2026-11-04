"""Live route audits may skip work only when source isolation still matches."""
import copy
import json
import os
from pathlib import Path
import subprocess
import unittest
import test_multi_uplink as multi
import test_openwrt_port as base


class RouteTests(unittest.TestCase):
    setUpClass = classmethod(multi.MultiUplinkTests.setUpClass.__func__)
    tearDownClass = classmethod(multi.MultiUplinkTests.tearDownClass.__func__)
    setUp = base.OpenWrtPortTests.setUp
    tearDown = base.OpenWrtPortTests.tearDown

    def fixture(self):
        ip='10.126.93.124';device='eth0';gateway='10.126.93.254';table=41000
        connected='10.126.93.0/24\nbroadcast'
        digest=2166136261
        for byte in connected.encode():digest=((digest^byte)*16777619)&0xffffffff
        (self.state/'routes-1-4').write_text(f'4 {table} {ip}/32 {device} {gateway} 1 {digest}\n')
        return {'routes':[
            {'family':4,'device':device,'destination':'10.126.93.0','prefix':24,'scope':253,'proto':2,'table':254,'type':1},
            {'family':4,'device':device,'destination':'10.126.93.255','prefix':32,'scope':253,'proto':2,'table':255,'type':3},
            {'family':4,'device':device,'prefix':0,'scope':0,'proto':16,'table':254,'type':1,'gateway':gateway},
            {'family':4,'device':device,'prefix':0,'scope':0,'proto':186,'table':table,'type':1,'gateway':gateway,'source':ip},
        ],'rules':[{'family':4,'device':device,'prefix':32,'proto':186,'priority':900,'table':table,'type':1,'source':ip}]}

    def audit(self, facts=None, ipv6=''):
        env=os.environ.copy()
        if facts is not None:
            file=self.temp/'facts.json';file.write_text(json.dumps(facts));env['BJUT_NATIVE_ROUTES']=str(file)
        return subprocess.run([self.codec.parent/'bjut-runtime','routes-current',self.state,'1','eth0','10.126.93.124','eth0',ipv6],
                              input='{}\nnull\n',env=env,text=True,capture_output=True)

    def test_exact_owned_rule_and_default_allow_the_read_only_path(self):
        result=self.audit(self.fixture())
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'managed not_configured\n')

    def test_source_device_protocol_priority_gateway_and_prefix_changes_require_repair(self):
        original=self.fixture()
        for section,index,key,value in (
            ('rules',0,'source','10.126.93.125'),('rules',0,'device','eth1'),
            ('rules',0,'proto',187),('rules',0,'priority',901),('rules',0,'table',41001),
            ('routes',3,'gateway','10.126.93.253'),('routes',3,'source','10.126.93.125'),
            ('routes',0,'prefix',25),
        ):
            with self.subTest(key=key,value=value):
                changed=copy.deepcopy(original);changed[section][index][key]=value
                result=self.audit(changed)
                self.assertEqual(result.returncode,75,result.stderr)
                self.assertEqual(result.stdout,'')

    def test_obsolete_ipv6_route_and_invalid_owner_cannot_be_reused(self):
        facts=self.fixture()
        file=self.state/'routes-1-6';file.write_text('6 41001 2001:db8::1/128 eth0 __direct 1 2166136261\n')
        self.assertEqual(self.audit(facts).returncode,75)
        file.unlink();file=self.state/'routes-1-4';file.write_text(file.read_text().replace(' eth0 ', ' other '))
        self.assertEqual(self.audit(facts).returncode,75)

    def test_live_kernel_dump_is_read_only_and_handles_missing_plugin_routes(self):
        result=self.audit()
        self.assertEqual(result.returncode,75,result.stderr)
        self.assertEqual(result.stdout,'')

    def test_ipv6_rules_and_preferred_sources_are_checked_independently(self):
        facts=self.fixture();ip='2001:db8::1';gateway='fe80::1'
        (self.state/'routes-1-6').write_text(f'6 41001 {ip}/128 eth0 {gateway} 1 2166136261\n')
        facts['routes'] += [
            {'family':6,'device':'eth0','prefix':0,'scope':0,'proto':16,'table':254,'type':1,'gateway':gateway},
            {'family':6,'device':'eth0','prefix':0,'scope':0,'proto':186,'table':41001,'type':1,'gateway':gateway,'source':ip},
        ]
        facts['rules'] += [{'family':6,'device':'eth0','prefix':128,'proto':186,'priority':900,'table':41001,'type':1,'source':ip}]
        result=self.audit(facts,ip)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'managed managed\n')
        facts['rules'][-1]['prefix']=64
        self.assertEqual(self.audit(facts,ip).returncode,75)

    def test_online_capture_rejects_login_and_error_bodies_and_unwraps_valid_lists(self):
        source=self.temp/'response';output=self.temp/'online'
        row={'sessionId':'fixture','ip':'192.0.2.1','downFlow':1024}
        for payload in ([row],{'rows':[row]},{'data':[row]},json.dumps([row]),None):
            source.write_text(json.dumps(payload))
            result=subprocess.run([self.codec.parent/'bjut-runtime','online-capture',source,output],capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(output.read_text()),[] if payload is None else [row])
        for payload in ('<html>login</html>',json.dumps({'error':'expired'}),json.dumps([{'sessionId':None}]),json.dumps([{'sessionId':'x'*257}])):
            source.write_text(payload)
            result=subprocess.run([self.codec.parent/'bjut-runtime','online-capture',source,output],capture_output=True)
            self.assertEqual(result.returncode,1,result.stderr)


if __name__=='__main__':unittest.main()
