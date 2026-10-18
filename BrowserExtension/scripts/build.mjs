import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
await build({
    entryPoints: [`${root}service-worker.mjs`],
    outfile: `${root}extension/service-worker.js`,
    bundle: true,
    format: 'esm',
    target: 'chrome120',
    minify: true,
    legalComments: 'eof'
});
