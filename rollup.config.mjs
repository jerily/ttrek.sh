import { fileURLToPath } from 'node:url';
import { readFile } from 'node:fs/promises';
import { buildAssets } from './assets/build.mjs';

const siteBundle = {
    input: 'assets/js/site.js',
    output: {
        file: 'public/js/site.js',
        format: 'es',
        banner: '/*! Includes throttle-debounce 5.0.2 (MIT); see search.LICENSE.txt. */',
    },
    plugins: [{
        name: 'resolve-throttle-debounce',
        resolveId(source) {
            if (source === 'throttle-debounce') {
                return fileURLToPath(import.meta.resolve(source));
            }
        },
    }, {
        name: 'vendored-clipboard',
        async load(id) {
            if (id === fileURLToPath(new URL('./public/js/clipboard.min.js', import.meta.url))) {
                // Adapt this vendored UMD bundle to a module without a global.
                return `const clipboard = { exports: {} };\n(function(module, exports) {\n${await readFile(id, 'utf8')}\n}).call(globalThis, clipboard, clipboard.exports);\nexport default clipboard.exports;`;
            }
        },
    }],
};

// Keep the old fixed search URL usable by pages rendered before this deployment.
// Current templates load only site.js, which includes both features.
export default [siteBundle, {
    input: 'assets/js/search.js',
    output: { ...siteBundle.output, file: 'public/js/search.js' },
    plugins: [siteBundle.plugins[0], {
        name: 'fingerprint-browser-assets',
        async writeBundle() { await buildAssets(); },
    }],
}];
