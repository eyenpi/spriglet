const { test, expect } = require('@playwright/test');
const AxeBuilder = require('@axe-core/playwright').default;
const source = require('../../../../Configuration/Shared/website.en-US.json').home;

async function openAt(page, hour = 14, minute = 32) {
  await page.clock.install({ time: new Date(2026, 9, 7, hour, minute) });
  await page.goto('/');
  await page.evaluate(() => document.fonts.ready);
}

test('field guide, adoption and existing help routes are reachable', async ({ page }) => {
  await openAt(page);
  await page.getByRole('navigation', { name: 'Main navigation' }).getByRole('link', { name: 'Field guide' }).click();
  await expect(page).toHaveURL(/#field-guide$/);
  await expect(page.getByRole('heading', { name: 'Mallow', exact: true })).toBeInViewport();
  await page.locator('.adopt-link').click();
  await expect(page).toHaveURL(/#bring-home$/);
  await expect(page.locator('.availability')).toHaveText(source.soonAvailability);
  await expect(page.locator('#bring-home a')).toHaveCount(0);
  await expect(page.locator('a[href*="/releases/"], a[href*="apps.apple.com"]')).toHaveCount(0);
  await expect(page.getByRole('navigation', { name: 'Main navigation' }).getByRole('link', { name: source.comingSoonAction })).toBeVisible();
  await page.getByRole('navigation', { name: 'Footer navigation' }).getByRole('link', { name: 'Support', exact: true }).click();
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Help & Support');
  await page.getByRole('link', { name: 'Privacy', exact: true }).click();
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Privacy Policy');
  await page.getByRole('link', { name: 'Spriglet home' }).click();
  await expect(page.getByRole('heading', { level: 1 })).toContainText('Someone small');
});

test('skip link and Mallow greeting work from the keyboard with visible focus', async ({ page, browserName }) => {
  await openAt(page);
  // WebKit on macOS uses Option-Tab to include links when Full Keyboard Access is off.
  await page.keyboard.press(browserName === 'webkit' ? 'Alt+Tab' : 'Tab');
  const skip = page.getByRole('link', { name: 'Skip to content' });
  await expect(skip).toBeFocused();
  await expect(skip).toBeInViewport();
  await expect(skip).toHaveCSS('outline-style', 'solid');
  await page.keyboard.press('Enter');
  await expect(page.locator('main')).toBeFocused();
  const hello = page.getByRole('button', { name: 'Say hello to Mallow' });
  await hello.focus();
  await expect(hello).toHaveCSS('outline-style', 'solid');
  await page.keyboard.press('Enter');
  await expect(page.locator('[data-clock]')).toHaveText('Hello, you. ♡');
  await expect(page.getByRole('status')).toHaveText('Hello, you. ♡');
  await page.clock.runFor(1000);
  await page.keyboard.press('Space');
  await page.clock.runFor(1500);
  await expect(page.locator('[data-clock]')).toHaveText('Hello, you. ♡');
  await page.clock.runFor(800);
  await expect(page.locator('[data-clock]')).toContainText('Mallow is awake');
  await expect(page.getByRole('status')).toBeEmpty();
  await expect(hello).toBeFocused();
});

for (const [hour, minute, period, mood] of [[4,59,'night','still here'],[5,0,'morning','stretching'],[11,59,'morning','stretching'],[12,0,'afternoon','awake'],[17,59,'afternoon','awake'],[18,0,'evening','winding down'],[21,59,'evening','winding down'],[22,0,'night','still here']]) {
  test(`local time ${hour}:${minute} selects ${period}`, async ({ page }) => {
    await openAt(page, hour, minute);
    await expect(page.locator('[data-time-scene]')).toHaveAttribute('data-period', period);
    await expect(page.locator('[data-clock]')).toContainText(`Mallow is ${mood}`);
    await expect(page.locator('[data-footer-clock]')).toContainText('It’s');
  });
}

test('minute and day boundaries refresh the clock and palette without navigation', async ({ page }) => {
  await openAt(page, 4, 59);
  await page.clock.runFor(60000);
  await expect(page.locator('[data-time-scene]')).toHaveAttribute('data-period', 'morning');
  await expect(page.locator('[data-clock]')).toContainText('5:00 AM');
  await page.clock.setSystemTime(new Date(2026, 9, 7, 23, 59));
  await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
  await page.clock.runFor(60000);
  await expect(page.locator('[data-clock]')).toContainText('12:00 AM');
  await expect(page.locator('[data-time-scene]')).toHaveAttribute('data-period', 'night');
});

test('no remote assets, browser errors or unexpected layout shifts on first load', async ({ page }) => {
  const errors = [];
  const remote = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  page.on('request', request => { if (!request.url().startsWith('http://127.0.0.1:8787')) remote.push(request.url()); });
  await page.addInitScript(() => {
    window.layoutShiftTotal = 0;
    if (PerformanceObserver.supportedEntryTypes.includes('layout-shift')) {
      new PerformanceObserver(list => { for (const entry of list.getEntries()) if (!entry.hadRecentInput) window.layoutShiftTotal += entry.value; }).observe({ type: 'layout-shift', buffered: true });
    }
  });
  await openAt(page);
  expect(errors).toEqual([]);
  expect(remote).toEqual([]);
  expect(await page.evaluate(() => window.layoutShiftTotal)).toBeLessThan(0.02);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(await page.evaluate(() => innerWidth));
});

test('content and primary navigation survive JavaScript being disabled', async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  await page.goto('http://127.0.0.1:8787/');
  await expect(page.getByRole('heading', { level: 1 })).toContainText('Someone small');
  await expect(page.locator('[data-clock]')).toHaveText('A little quiet company.');
  await expect(page.getByRole('button', { name: 'Say hello to Mallow' })).toBeDisabled();
  await page.locator('.hero .button').click();
  await expect(page).toHaveURL(/#bring-home$/);
  await expect(page.locator('.availability')).toHaveText(source.soonAvailability);
  await expect(page.locator('#bring-home a')).toHaveCount(0);
  await context.close();
});

test('missing fonts preserve readable content and release availability', async ({ page }) => {
  await page.route('**/*.woff2', route => route.abort());
  await openAt(page);
  await expect(page.getByRole('heading', { level: 1 })).toContainText('Someone small');
  await page.locator('.hero .button').click();
  await expect(page.locator('.availability')).toBeInViewport();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(await page.evaluate(() => innerWidth));
});

test('320px reflow and larger text retain all content without horizontal scrolling', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 900 });
  await openAt(page);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(320);
  await page.locator('.availability').scrollIntoViewIfNeeded();
  await expect(page.locator('.availability')).toBeInViewport();
  // 200% text scaling checks fixed ornaments against readable content.
  await page.evaluate(() => {
    const sheet = [...document.styleSheets].find(item => item.href?.endsWith('/home.css'));
    sheet.insertRule('p:not(.micro), dd { font-size: 1.75rem !important; overflow-wrap: anywhere; }', sheet.cssRules.length);
  });
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(320);
});

test('Reduce Motion keeps the greeting still', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await openAt(page);
  await page.getByRole('button', { name: 'Say hello to Mallow' }).click();
  await expect(page.locator('.hero-mallow')).toHaveCSS('transform', 'none');
  await expect(page.locator('.hero-mallow')).toHaveCSS('transition-duration', '0s');
  await expect(page.locator('[data-clock]')).toHaveText('Hello, you. ♡');
});

for (const hour of [7,14,19,23]) {
  test(`accessibility and contrast at ${hour}:00`, async ({ page }) => {
    await openAt(page, hour, 0);
    const result = await new AxeBuilder({ page }).withTags(['wcag2a','wcag2aa','wcag21a','wcag21aa']).analyze();
    expect(result.violations.map(({ id, nodes }) => ({ id, elements: nodes.map(node => node.target) }))).toEqual([]);
  });
}

test('unknown routes offer recovery and security policy blocks outbound connections', async ({ page, request }) => {
  const response = await request.get('/');
  expect(response.status()).toBe(200);
  expect(response.headers()['content-security-policy']).toContain("connect-src 'none'");
  const support = await request.get('/support');
  expect(support.headers()['content-security-policy']).toContain("script-src 'none'");
  await page.goto('/missing-spriglet-page');
  await expect(page.getByRole('heading', { name: 'Page not found' })).toBeVisible();
  await page.getByRole('link', { name: 'Spriglet home' }).click();
  await expect(page.getByRole('heading', { level: 1 })).toContainText('Someone small');
});
