/* Ship built assets so Finder setup does not require Node.js. */
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
function buildApp(preview = false) {
  const out = path.join(root, preview ? '.local/design-preview/site' : 'app/reader/dist');
  fs.mkdirSync(out, { recursive: true });
  require('esbuild').buildSync({ entryPoints: [path.join(root, 'app/reader/src/app.tsx')], outfile: path.join(out, 'app.js'), bundle: true, minify: true, jsx: 'automatic', target: ['safari17.2'], define: { 'process.env.NODE_ENV': '"production"' }, tsconfig: path.join(root, 'dev/config/tsconfig.json'), legalComments: 'eof' });
  // Keep both backdrop-filter spellings: CSS minification can drop Chromium's.
  execFileSync(path.join(root, 'node_modules/.bin/tailwindcss'), ['-i', path.join(root, 'app/reader/src/app.css'), '-o', path.join(out, 'app.css')], { cwd: root, stdio: 'inherit' });
  let html = fs.readFileSync(path.join(root, 'app/reader/src/index.html'), 'utf8');
  if (preview) html = html.replace('</head>', '<meta name="openread-api-prefix" content="/api"></head>');
  fs.writeFileSync(path.join(out, 'index.html'), html);
  if (preview) fs.copyFileSync(path.join(root, 'extension/icons/128.png'), path.join(out, 'icon.png'));
  console.log(`Built OpenRead ${preview ? 'isolated preview' : 'reading app'}.`);
}
module.exports = buildApp;
if (require.main === module) buildApp(process.argv.includes('--preview'));
