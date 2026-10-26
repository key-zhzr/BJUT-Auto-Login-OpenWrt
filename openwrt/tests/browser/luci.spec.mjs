import { expect, test } from '@playwright/test';
import { readFile } from 'node:fs/promises';

test('LuCI six-page regression suite and PushPlus diagnostic states', async ({ page }) => {
  await page.route('**/*',route=>new URL(route.request().url()).hostname==='127.0.0.1'?route.continue():route.abort());
  await page.setViewportSize({ width: 1366, height: 900 });
  await page.goto('/tests/luci-regression.html');

  const navButtons = page.locator('#tabs button');
  await expect(navButtons).toHaveCount(6);
  await expect(navButtons).toContainText([
    '控制台',
    '账号管理',
    '计费系统',
    '网络诊断',
    '运行日志',
    '设置',
  ]);

  const runQa = page.locator('#run-router-qa');
  await expect(runQa).toBeEnabled();
  await runQa.click();

  const results = page.locator('#router-qa-results');
  await expect(results).toContainText('全部通过', { timeout: 30000 });
  await expect(results).not.toContainText('失败：');
  await expect(results).toContainText('通过：账号管理启停、排序与添加编辑弹窗');
  await expect(results).toContainText('通过：网络诊断双栈状态与诊断包导出');
  await expect(results).toContainText('通过：设置页面与 PushPlus 排队/失败码/已受理状态');

  await expect(page.locator('#content > [data-qa-view="overview"]')).toBeVisible();
  await page.locator('#hide-router-qa').click();
  const traffic = page.locator('.bj-device-usage');
  await expect(traffic.getByRole('button',{name:'开启统计',exact:true})).toBeVisible();
  await expect(traffic.locator('.traffic-content')).toBeHidden();
  await traffic.getByRole('button',{name:'开启统计',exact:true}).click();
  await expect(traffic.locator('.traffic-content')).toBeVisible();
  await expect(traffic.locator('.traffic-line')).toHaveCount(1);
  await traffic.getByLabel('时间范围',{exact:true}).selectOption('3600');
  await traffic.getByLabel('曲线',{exact:true}).selectOption('interfaces');
  await expect(traffic.locator('.traffic-line')).toHaveCount(2);
  await traffic.locator('.traffic-interfaces').getByText('lan4',{exact:true}).click();
  await expect(traffic.locator('.traffic-line')).toHaveCount(1);
  await traffic.getByLabel('流量显示',{exact:true}).selectOption('cumulative');
  await traffic.locator('.traffic-plot').focus();await page.keyboard.press('End');
  await expect(traffic.locator('.traffic-tooltip')).toBeVisible();
  await expect(traffic.locator('.traffic-tooltip')).toContainText('lan3');
  const download = page.waitForEvent('download');
  await traffic.getByRole('button', { name: '导出 CSV', exact: true }).click();
  const file = await download;expect(file.suggestedFilename()).toBe('device-usage.csv');
  const csv = await readFile(await file.path(), 'utf8');expect(csv).toContain('lan3');expect(csv).not.toContain('lan4');
  await page.waitForTimeout(5500);
  await expect(traffic.getByLabel('流量显示',{exact:true})).toHaveValue('cumulative');
  await expect(traffic.locator('.traffic-line')).toHaveCount(1);
  await traffic.locator('summary').click();await expect(traffic).toContainText('512.50 MB');
  await traffic.getByRole('button',{name:'暂停统计',exact:true}).click();
  await expect(traffic.locator('.traffic-content')).toBeHidden();

  await page.setViewportSize({ width: 390, height: 844 });
  for (const viewId of ['overview', 'accounts', 'billing', 'diagnostics', 'logs', 'config']) {
    await page.locator(`#tabs button[data-view="${viewId}"]`).click();
    await expect(page.locator(`#content > [data-qa-view="${viewId}"]`)).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - window.innerWidth,
    );
    expect(overflow).toBeLessThanOrEqual(1);
  }
});
