import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';
import { buildAssets, stylesheets } from '../assets/build.mjs';

test('fingerprints track exact bytes, rebuilds are stable, and old URLs survive', async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), 'ttrek-assets-'));
    const put = async (filename, bytes) => {
        const target = path.join(root, filename);
        await mkdir(path.dirname(target), { recursive: true });
        await writeFile(target, bytes);
    };
    try {
        const sources = {
            'public/css/nested/theme.css': '/* café */\r\nbody {color: red;}\r\n',
            'public/js/search.js': 'export const search = true;\n',
            'public/js/clipboard.min.js': '// clipboard\n',
            'node_modules/chart.js/dist/chart.umd.js': '// chart\n',
            'node_modules/chart.js/LICENSE.md': 'chart license',
            'node_modules/@kurkle/color/LICENSE.md': 'color license',
            'node_modules/throttle-debounce/LICENSE.md': 'search license',
        };
        for (const [name, bytes] of Object.entries(sources)) await put(name, bytes);
        for (const filename of stylesheets) await put(`public/css/${filename}`, `/* ${filename} */\n`);
        const first = await buildAssets(root);
        assert.equal(Object.keys(first).length, 4 + stylesheets.length + 1);
        assert.equal(await readFile(path.join(root, 'public/css/site.css'), 'utf8'), stylesheets.map(name => `/* ${name} */\n\n`).join(''));
        for (const [original, hashed] of Object.entries(first)) {
            const bytes = await readFile(path.join(root, 'public', original));
            const digest = createHash('sha256').update(bytes).digest('hex').slice(0, 16);
            assert.ok(hashed.endsWith(`.${digest}${path.extname(original)}`));
            assert.deepEqual(await readFile(path.join(root, 'public', hashed)), bytes);
        }
        assert.equal(await readFile(path.join(root, 'public/assets/versioned/js/chart.LICENSE.txt'), 'utf8'), 'chart license');
        assert.deepEqual(await buildAssets(root), first);
        await put('public/css/nested/theme.css', 'body {color: tan;}\n');
        const second = await buildAssets(root);
        assert.notEqual(second['/css/nested/theme.css'], first['/css/nested/theme.css']);
        assert.equal(second['/js/search.js'], first['/js/search.js']);
        assert.equal(await readFile(path.join(root, 'public', first['/css/nested/theme.css']), 'utf8'), sources['public/css/nested/theme.css']);
        assert.deepEqual(JSON.parse(await readFile(path.join(root, 'public/asset-manifest.json'), 'utf8')), second);
        // A failed build must leave the last complete manifest in place.
        await rm(path.join(root, 'node_modules/chart.js/dist/chart.umd.js'));
        await assert.rejects(buildAssets(root));
        assert.deepEqual(JSON.parse(await readFile(path.join(root, 'public/asset-manifest.json'), 'utf8')), second);
    } finally {
        await rm(root, { recursive: true, force: true });
    }
});

test('the combined browser bundle initializes clipboard without a global vendor script', async () => {
    const listeners = [];
    const document = {
        querySelector: () => ({}),
        querySelectorAll: () => [],
        body: { addEventListener: name => listeners.push(name) },
    };
    const context = { document, HTMLElement: class {}, setTimeout, clearTimeout };
    const source = await readFile(new URL('../public/js/site.js', import.meta.url), 'utf8');
    // The browser loads this as type=module; model its private top-level scope.
    runInNewContext(`(function() {\n${source}\n})();`, context);
    assert.deepEqual(listeners, ['click']);
    assert.equal(context.ClipboardJS, undefined);
    // Pages without either feature must also run without errors or listeners.
    listeners.length = 0;
    document.querySelector = () => null;
    runInNewContext(`(function() {\n${source}\n})();`, { ...context });
    assert.deepEqual(listeners, []);
});
