// Optional browser checks against HTML rendered from disposable local fixtures.
import assert from 'node:assert/strict';
import http from 'node:http';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = fileURLToPath(new URL('../', import.meta.url));
const fixtures = path.resolve(process.argv[2] || '/tmp/ttrek-languages-preview');
const publicRoot = path.join(root, 'public');
const routes = { '/': 'home.html', '/packages': 'packages.html', '/package/topenapi': 'overview.html',
    '/package/topenapi/0.2.0': 'version.html', '/package/tjson/1.0.26': 'legacy.html' };
const server = http.createServer(async (req, res) => {
    try {
        const url = new URL(req.url, 'http://localhost');
        let filename;
        if (routes[url.pathname]) {
            const fixture = url.pathname === '/packages' && url.searchParams.get('language') === 'tcl-c-cpp'
                ? 'filtered.html' : routes[url.pathname];
            filename = path.join(fixtures, fixture);
        } else {
            filename = path.resolve(publicRoot, `.${decodeURIComponent(url.pathname)}`);
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
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(String(error)));
    for (const width of [320, 390, 768, 1440]) {
        await page.setViewportSize({ width, height: 1000 });
        for (const route of Object.keys(routes)) {
            assert.equal((await page.goto(base + route)).status(), 200);
            assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `${route}: overflow at ${width}`);
            if (route === '/') assert.equal(await page.locator('[name="language"]').count(), 0);
            if (route === '/package/topenapi/0.2.0') {
                assert.deepEqual(await page.locator('.package-languages li').allTextContents(), ['C', 'C++', 'TCL']);
                assert.equal(await page.locator('[aria-current="page"]').textContent(), '0.2.0');
                await page.screenshot({ path: path.join(fixtures, `version-${width}.png`), fullPage: true });
            }
            if (route === '/packages' && width === 1440) {
                const filter = await page.locator('.language-filter').boundingBox();
                const search = await page.locator('.search-field').boundingBox();
                assert(filter.x + filter.width <= search.x, 'Language filter is left of search');
            }
        }
    }
    await page.goto(base + '/packages');
    assert.equal(await page.locator('[name="language"]').inputValue(), '');
    assert.deepEqual(await page.locator('[name="language"] option').allTextContents(),
        ['Any', 'Only TCL', 'TCL and C/C++', 'Only C or C++']);
    const all = await page.locator('.package-card').count();
    await page.selectOption('[name="language"]', 'tcl-c-cpp');
    await page.waitForURL(url => url.searchParams.get('language') === 'tcl-c-cpp');
    assert.equal(await page.locator('[name="language"]').inputValue(), 'tcl-c-cpp');
    assert(await page.locator('.package-card').count() < all);
    await page.screenshot({ path: path.join(fixtures, 'filtered-desktop.png'), fullPage: true });
    await page.route('**/registry/autocomplete?*', route => route.fulfill({ json: [] }));
    const autocomplete = page.waitForRequest(request => new URL(request.url()).pathname === '/registry/autocomplete');
    await page.locator('[name="q"]').fill('tjson');
    const suggestionQuery = new URL((await autocomplete).url()).searchParams;
    assert.equal(suggestionQuery.get('q'), 'tjson');
    assert.equal(suggestionQuery.get('language'), 'tcl-c-cpp');
    await page.locator('button[type="submit"]').click();
    await page.waitForURL(url => url.searchParams.get('q') === 'tjson');
    assert.equal(new URL(page.url()).searchParams.get('language'), 'tcl-c-cpp');
    assert.deepEqual(errors, []);
    console.log('Package overview, version pages and language dropdown passed at 320, 390, 768 and 1440 px.');
} finally {
    await browser?.close();
    await new Promise(resolve => server.close(resolve));
}
