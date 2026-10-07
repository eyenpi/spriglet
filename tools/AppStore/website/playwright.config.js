const { defineConfig } = require('@playwright/test');
module.exports = defineConfig({
  testDir: './tests',
  outputDir: '../../../.build/homepage/test-results',
  reporter: [['list']],
  fullyParallel: true,
  use: { baseURL: 'http://127.0.0.1:8787', trace: 'retain-on-failure' },
  projects: [
    { name: 'desktop', use: { browserName: 'chromium', viewport: { width: 1440, height: 1000 } } },
    { name: 'tablet', use: { browserName: 'chromium', viewport: { width: 768, height: 1024 } } },
    { name: 'mobile', use: { browserName: 'chromium', viewport: { width: 390, height: 844 } } },
    { name: 'webkit', use: { browserName: 'webkit', viewport: { width: 1440, height: 1000 } } }
  ],
  webServer: {
    command: '../../../tools/WebsiteDeployment/node_modules/.bin/wrangler dev --config wrangler.jsonc --ip 127.0.0.1 --port 8787',
    url: 'http://127.0.0.1:8787',
    reuseExistingServer: !process.env.CI,
    env: { WRANGLER_SEND_METRICS: 'false' },
    timeout: 60000
  }
});
