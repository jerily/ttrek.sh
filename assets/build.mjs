import { createHash } from 'node:crypto';
import { copyFile, mkdir, readFile, readdir, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';

export const fingerprint = bytes => createHash('sha256').update(bytes).digest('hex').slice(0, 16);

// Preserve the existing cascade: framework, shared layout, then scoped pages.
export const stylesheets = [
    'pure/pure-min.css', 'pure/grids-responsive-min.css', 'styles.css',
    'search.css', 'home-showcase.css', 'docs.css', 'request-monitor.css',
];

async function files(directory) {
    const result = [];
    for (const entry of await readdir(directory, { withFileTypes: true })) {
        const filename = path.join(directory, entry.name);
        if (entry.isDirectory()) result.push(...await files(filename));
        else if (entry.isFile()) result.push(filename);
    }
    return result.sort();
}

// Run after Rollup writes site.js. Keep fixed URLs for older clients and never
// remove previous fingerprints: open pages may still request an earlier build.
export async function buildAssets(root = process.cwd()) {
    const publicRoot = path.join(root, 'public');
    const versioned = path.join(publicRoot, 'assets/versioned');
    await mkdir(path.join(versioned, 'js'), { recursive: true });
    const vendorFiles = {
        'chart.js/dist/chart.umd.js': 'chart.umd.js',
        'chart.js/LICENSE.md': 'chart.LICENSE.txt',
        '@kurkle/color/LICENSE.md': 'chart-color.LICENSE.txt',
        'throttle-debounce/LICENSE.md': 'search.LICENSE.txt',
    };
    for (const [source, target] of Object.entries(vendorFiles)) {
        await copyFile(path.join(root, 'node_modules', source), path.join(publicRoot, 'js', target));
    }
    const css = [];
    for (const filename of stylesheets) {
        css.push(await readFile(path.join(publicRoot, 'css', filename)));
        css.push(Buffer.from('\n'));
    }
    await writeFile(path.join(publicRoot, 'css/site.css'), Buffer.concat(css));
    const manifest = {};
    for (const kind of ['css', 'js']) {
        for (const filename of await files(path.join(publicRoot, kind))) {
            const relative = path.relative(publicRoot, filename).split(path.sep).join('/');
            const bytes = await readFile(filename);
            const extension = path.extname(filename);
            if (!['.css', '.js'].includes(extension)) {
                // Preserve adjacent license files referenced by bundle comments.
                const target = path.join(versioned, relative);
                await mkdir(path.dirname(target), { recursive: true });
                await writeFile(target, bytes);
                continue;
            }
            const hashed = `${relative.slice(0, -extension.length)}.${fingerprint(bytes)}${extension}`;
            const target = path.join(versioned, hashed);
            await mkdir(path.dirname(target), { recursive: true });
            await writeFile(target, bytes);
            manifest[`/${relative}`] = `/assets/versioned/${hashed}`;
        }
    }
    const filename = path.join(publicRoot, 'asset-manifest.json');
    await writeFile(`${filename}.tmp`, `${JSON.stringify(manifest, null, 2)}\n`);
    await rename(`${filename}.tmp`, filename);
    return manifest;
}
