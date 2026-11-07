import { fileURLToPath } from 'node:url';

export default {
    input: 'assets/js/search.js',
    output: {
        file: 'public/js/search.js',
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
    }],
};
