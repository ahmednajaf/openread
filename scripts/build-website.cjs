const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..'); const out = path.join(root, 'website/dist');
fs.mkdirSync(out, { recursive: true });
require('esbuild').buildSync({ entryPoints: [path.join(root, 'website/src/app.tsx')], outfile: path.join(out, 'site.js'), bundle: true, minify: true, target: ['safari17.2'], jsx: 'automatic', define: { 'process.env.NODE_ENV': '"production"' }, tsconfig: path.join(root, 'tsconfig.json'), legalComments: 'eof' });
fs.copyFileSync(path.join(root, 'website/src/site.css'), path.join(out, 'site.css'));
fs.cpSync(path.join(root, 'website/public'), out, { recursive: true });
const host = process.env.SITE_URL || (process.env.VERCEL_PROJECT_PRODUCTION_URL ? 'https://' + process.env.VERCEL_PROJECT_PRODUCTION_URL : '');
let social = '<meta property="og:image" content="/social.png"><meta name="twitter:image" content="/social.png">';
if (host) {
  const url = new URL(host); if (url.protocol !== 'https:') throw new Error('SITE_URL must use HTTPS.');
  const origin = url.origin;
  social = `<link rel="canonical" href="${origin}/"><meta property="og:url" content="${origin}/"><meta property="og:image" content="${origin}/social.png"><meta name="twitter:image" content="${origin}/social.png"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">`;
  fs.writeFileSync(path.join(out, 'sitemap.xml'), `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>${origin}/</loc></url></urlset>`);
}
fs.writeFileSync(path.join(out, 'index.html'), fs.readFileSync(path.join(root, 'website/src/index.html'), 'utf8').replace('<!-- SOCIAL_URLS -->', social));
fs.writeFileSync(path.join(out, 'robots.txt'), 'User-agent: *\nAllow: /\n' + (host ? `Sitemap: ${new URL(host).origin}/sitemap.xml\n` : ''));
console.log('Built public website: website/dist (static; no local helper or models included).');
