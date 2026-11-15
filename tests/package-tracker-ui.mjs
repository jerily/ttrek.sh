// Optional browser regression test; no production services or test dependencies in the bundle.
import assert from 'node:assert/strict';
import http from 'node:http';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = fileURLToPath(new URL('../', import.meta.url));
const fixtures = path.resolve(process.argv[2] || '/tmp/ttrek-tracker-preview');
const publicRoot = path.join(root, 'public');
const routes = { '/packages': 'packages.html', '/packages/tracker': 'tracker.html', '/package/rising': 'package.html' };
const server = http.createServer(async (req, res) => {
    try {
        const pathname = new URL(req.url, 'http://localhost').pathname;
        let filename;
        if (routes[pathname]) filename = path.join(fixtures, routes[pathname]);
        else {
            filename = path.resolve(publicRoot, `.${decodeURIComponent(pathname)}`);
            if (!filename.startsWith(publicRoot + path.sep)) throw new Error('Invalid path');
        }
        const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' };
        res.writeHead(200, { 'Content-Type': types[path.extname(filename)] || 'application/octet-stream' });
        res.end(await readFile(filename));
    } catch { res.writeHead(404); res.end('Not found'); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;
let browser;
try {
    browser = await chromium.launch({ executablePath: process.env.PLAYWRIGHT_EXECUTABLE || undefined });
    const errors = [];
    const page = await browser.newPage();
    page.on('pageerror', error => errors.push(String(error)));
    for (const width of [320, 390, 768, 1440]) {
        await page.setViewportSize({ width, height: 1000 });
        for (const route of Object.keys(routes)) {
            await page.goto(base + route);
            assert.equal(await page.locator('main').count(), 1);
            assert.equal(await page.locator('.home-menu .pure-menu-selected a').getAttribute('href'), '/packages');
            assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, `${route} overflows at ${width}px`);
            if (route === '/packages/tracker') {
                const lengths = await page.locator('.tracker-section').evaluateAll(sections => sections.map(section => section.querySelectorAll('ol li').length));
                assert.equal(lengths.length, 4);
                assert.ok(lengths.every(n => n <= 5));
                assert.equal(lengths[0], 5);
            }
            if (route === '/packages') {
                await page.waitForSelector('.tracker-bar.is-enhanced');
                assert.equal(await page.getByRole('link', { name: 'See top packages →' }).getAttribute('href'), '/packages/tracker');
                assert.equal(await page.locator('.tracker-panel.is-active .tracker-item:visible').count(), 3);
            }
            if (route === '/package/rising') {
                await page.waitForFunction(() => window.Chart?.getChart(document.querySelector('canvas'))?.width > 0);
                const data = await page.evaluate(() => Chart.getChart(document.querySelector('canvas')).data.datasets[0].data);
                assert.ok(data.length >= 30 && data.some(value => value > 0));
            }
        }
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.clock.install({ time: 0 });
    await page.clock.pauseAt(1);
    await page.goto(base + '/packages');
    await page.mouse.move(0, 0);
    await page.waitForTimeout(100);
    await page.clock.runFor(100);
    const current = () => page.locator('.tracker-panel.is-active').getAttribute('data-tracker-panel');
    assert.equal(await current(), 'new');
    await page.clock.runFor(8100);
    assert.equal(await current(), 'updated');
    await page.locator('[data-tracker-rotation]').click();
    await page.mouse.move(0, 0);
    await page.clock.runFor(20000);
    assert.equal(await current(), 'updated');
    await page.locator('[data-tracker-select="trending"]').click();
    assert.equal(await current(), 'trending');
    await page.locator('[data-tracker-select="trending"]').press('Home');
    assert.equal(await current(), 'new');
    await page.clock.runFor(20000);
    assert.equal(await current(), 'new');
    await page.locator('[data-tracker-rotation]').click();
    await page.mouse.move(0, 0);
    await page.clock.runFor(8100);
    assert.equal(await current(), 'updated');
    await page.locator('.tracker-item:visible').first().hover();
    await page.clock.runFor(20000);
    assert.equal(await current(), 'updated');
    assert.equal(await page.locator('.tracker-panel').evaluateAll(panels => panels.filter(panel => !panel.inert).length), 1);
    assert.equal(await page.evaluate(() => document.activeElement?.getAttribute('data-tracker-rotation')), '');

    const reduced = await browser.newPage({ reducedMotion: 'reduce' });
    await reduced.goto(base + '/packages');
    assert.equal(await reduced.locator('[data-tracker-rotation]').isVisible(), false);
    await reduced.locator('[data-tracker-select="popular"]').click();
    assert.equal(await reduced.locator('.tracker-panel.is-active').getAttribute('data-tracker-panel'), 'popular');
    await reduced.close();

    // Swipes switch categories, stop rotation, and leave taps/scroll gestures alone.
    const touch = await browser.newPage({ viewport: { width: 390, height: 900 }, hasTouch: true });
    await touch.goto(base + '/packages');
    const touchCurrent = () => touch.locator('.tracker-panel.is-active').getAttribute('data-tracker-panel');
    async function swipe(dx, dy = 0, cancel = false) {
        const surface = touch.locator('.tracker-panels');
        const pointer = { pointerId: 1, pointerType: 'touch', isPrimary: true, clientX: 200, clientY: 100 };
        await surface.dispatchEvent('pointerdown', pointer);
        await surface.dispatchEvent(cancel ? 'pointercancel' : 'pointerup', { ...pointer, clientX: 200 + dx, clientY: 100 + dy });
    }
    await swipe(-100);
    assert.equal(await touchCurrent(), 'updated');
    assert.equal(await touch.locator('[data-tracker-rotation]').textContent(), 'Play');
    await swipe(100);
    assert.equal(await touchCurrent(), 'new');
    await swipe(100);
    assert.equal(await touchCurrent(), 'trending');
    for (const gesture of [[-10, 0], [-50, 100], [-100, 0, true]]) {
        await swipe(...gesture);
        assert.equal(await touchCurrent(), 'trending');
    }
    assert.equal(await touch.locator('.tracker-panel.is-active .tracker-item:visible').count(),
        await touch.locator('.tracker-panel.is-active .tracker-item').count());
    await touch.close();

    const plain = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 390, height: 900 } });
    const noJS = await plain.newPage();
    await noJS.goto(base + '/packages');
    assert.equal(await noJS.locator('.tracker-panel:visible').count(), 1);
    assert.equal(await noJS.locator('.tracker-bar-controls').isVisible(), false);
    await noJS.goto(base + '/package/rising');
    await noJS.locator('.activity-data summary').click();
    assert.ok(await noJS.locator('.activity-data tbody tr:visible').count() >= 30);
    await plain.close();

    // Compare geometry while the bundle is held, including the mobile controls.
    for (const width of [390, 1440]) {
        const loading = await browser.newPage({ viewport: { width, height: 1000 } });
        let release;
        const gate = new Promise(resolve => { release = resolve; });
        await loading.route('**/js/site.*.js', async route => { await gate; await route.continue(); });
        await loading.goto(base + '/packages', { waitUntil: 'commit' });
        await loading.waitForSelector('.tracker-bar');
        const before = await loading.locator('.results-heading').boundingBox();
        release();
        await loading.waitForSelector('.tracker-bar.is-enhanced');
        const after = await loading.locator('.results-heading').boundingBox();
        assert.equal(after.y, before.y, `layout shift at ${width}px`);
        await loading.close();
    }
    await page.goto(base + '/packages/tracker');
    await page.screenshot({ path: path.join(fixtures, 'tracker-desktop.png'), fullPage: true });
    await page.goto(base + '/package/rising');
    await page.screenshot({ path: path.join(fixtures, 'package-desktop.png'), fullPage: true });
    await page.setViewportSize({ width: 390, height: 1000 });
    await page.goto(base + '/packages');
    await page.screenshot({ path: path.join(fixtures, 'packages-mobile.png'), fullPage: true });
    assert.deepEqual(errors, []);
    console.log('PASS tracker layout at 320/390/768/1440px, mobile package list, swipes, 5-entry sections, chart, rotation, pause, keyboard, hover, reduced motion, no-JS and stable loading geometry');
} finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
}
