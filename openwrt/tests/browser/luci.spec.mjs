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
  const traffic = page.locator('.bj-device-usage');
  await expect(traffic).toContainText('512.50 MB');
  await traffic.locator('[data-traffic-filter="account"]').selectOption('25000001');
  await traffic.locator('[data-traffic-filter="period"]').selectOption('month');
  await expect(traffic.locator('.bj-traffic-history')).toContainText('每月采样新增流量');
  await expect(traffic.locator('.bj-traffic-history')).toContainText('2.00 GB');
  await traffic.locator('[data-traffic-filter="range"]').selectOption('90');
  await expect(traffic.locator('.bj-traffic-history')).toContainText('采样新增流量 4.00 GB');
  const download = page.waitForEvent('download');
  await traffic.getByRole('button', { name: '导出 CSV', exact: true }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe('device-usage.csv');
  const csv = await readFile(await file.path(), 'utf8');
  expect(csv).toContain('25000001');
  expect(csv).not.toContain('25000002');
  await page.waitForTimeout(5500);
  await expect(traffic.locator('[data-traffic-filter="account"]')).toHaveValue('25000001');
  await expect(traffic.locator('[data-traffic-filter="period"]')).toHaveValue('month');

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
