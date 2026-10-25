import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  testMatch: 'luci.spec.mjs',
  timeout: 60000,
  use: {
    baseURL: 'http://127.0.0.1:4176',
    headless: true,
    channel: process.env.BJUT_TEST_BROWSER || undefined,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  webServer: {
    command: 'python3 -m http.server 4176 --bind 127.0.0.1 --directory ../..',
    url: 'http://127.0.0.1:4176/tests/luci-regression.html',
    reuseExistingServer: !process.env.CI,
  },
});
