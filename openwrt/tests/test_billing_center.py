import json
import unittest
from pathlib import Path
import test_router_revision10 as revision


class BillingCenterTests(revision.RouterRevision10Tests):
    # Keep this suite focused; reuse the fixture helpers, not its test methods.
    def test_bundle_uses_one_verified_login_and_publishes_all_modules(self):
        env = self.config()
        value, ticket = self.worker('billing_details', {'uplink':'dorm_a','account':'account1','owner':'1'*32,'module':'center'},env)
        result = value['result']
        self.assertEqual(result['state'],'ready',value)
        self.assertEqual(result['account'],'25000001')
        self.assertEqual(result['overview']['account'],'25000001')
        self.assertEqual(set(result['modules']),{'services','devices','security','history'})
        for name,item in result['modules'].items():
            self.assertEqual(item['state'],'ready',item)
            self.assertEqual(item['module'],name)
            self.assertEqual(item['account'],result['account'])
        self.assertNotIn('userPassword',json.dumps(value))
        self.assertNotIn('fixture-session',json.dumps(value))
        self.assertEqual(self.requests().count('URL https://jfself.bjut.edu.cn/Self/login/verify\n'),1)
        package = result['modules']['services']['packages'][0]
        self.assertEqual(package,{'id':'2','name':'新套餐','description':'测试'})

    def test_current_package_missing_from_offered_choices_is_retained(self):
        env=self.config();dashboard=self.temp/'dashboard.html'
        dashboard.write_text('<script>(function(user){window.user=user;})({"userName":"25000001","useFlag":1,"installmentFlag":0,"useMoney":0,"serviceDefault":{"id":1,"defaultName":"默认套餐","extend":"每月赠送30GB"}});</script>')
        context=dict(env,MOCK_BILLING_DASHBOARD=str(dashboard),MOCK_PACKAGE_RESERVATION='1')
        value,ticket=self.worker('billing_details',{'uplink':'dorm_a','account':'account1','owner':'1'*32,'module':'services'},context)
        service=value['result']
        self.assertEqual(service['currentPackageId'],'1')
        self.assertEqual(service['currentPackage'],'默认套餐')
        self.assertEqual(service['packages'][0],{'id':'1','name':'默认套餐','description':'每月赠送30GB'})
        self.assertEqual(service['scheduledPackage'],'新套餐')
        self.assertEqual(service['canCancel'],1)
        self.assertEqual(service['installmentFlag'],'0','dashboard values take precedence over optional service pages')
        rejected,_=self.worker('billing_action',{'ticket':ticket,'owner':'1'*32,'operation':'schedulePackage','payload':'{"packageId":"1"}'},context)
        self.assertEqual(rejected['result']['state'],'error')
        self.assertIn('当前正在使用',rejected['result']['message'])
        self.assertNotIn('URL https://jfself.bjut.edu.cn/Self/service/doPackage\n',self.requests())

    def test_full_center_does_not_accept_foreign_owner(self):
        env=self.config()
        value,ticket=self.worker('billing_details',{'uplink':'dorm_a','account':'account1','owner':'1'*32,'module':'center'},env)
        denied=self.rpc('billing_poll',{'ticket':ticket,'owner':'2'*32},**env)
        self.assertEqual(json.loads(denied.stdout)['state'],'error')


# Inherited tests run in their original suite.
for name in list(dir(BillingCenterTests)):
    if name.startswith('test_') and name not in BillingCenterTests.__dict__:
        setattr(BillingCenterTests,name,None)

if __name__=='__main__':unittest.main()
