/* Local-only design review, with a separate library and the real local models. */
const fs = require('node:fs'); const path = require('node:path'); const http = require('node:http'); const { spawn, execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..'); execFileSync(process.execPath, [path.join(__dirname, 'build-design.cjs')], { stdio: 'inherit' });
const site = path.join(root, '.local/design-preview/site');
const helperCode = `from pathlib import Path\nfrom voice.server import KokoroVoice,make_server\nfrom voice.features import Library\nserver=make_server(KokoroVoice(),port=8767,library=Library(Path('.local/design-preview/library.sqlite3')))\ntry:\n server.serve_forever()\nexcept KeyboardInterrupt:\n pass\nfinally:\n server.server_close()`;
const helper = spawn(path.join(root, '.venv/bin/python'), ['-u', '-c', helperCode], { cwd: root, stdio: 'inherit' });
const routes = new Set(['/health','/capabilities','/library','/library/save','/library/delete','/transcribe','/import','/synthesize','/ai','/export','/jobs/cancel']);
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1:4180');
  if (req.headers.host !== '127.0.0.1:4180') { res.writeHead(403); res.end(); return; }
  if (url.pathname.startsWith('/api/')) {
    const route = url.pathname.slice(4);
    if (!routes.has(route) && !/^\/(jobs|library)\/[\w-]+$/.test(route)) { res.writeHead(404); res.end(); return; }
    if (req.headers.origin && req.headers.origin !== 'http://127.0.0.1:4180') { res.writeHead(403); res.end(); return; }
    if (req.headers['x-openread'] !== '1') { res.writeHead(403); res.end(); return; }
    const upstream = http.request({ hostname:'127.0.0.1', port:8767, path:route+url.search, method:req.method, headers:{ 'X-OpenRead':'1', 'Content-Type':'application/json', ...(req.headers['content-length'] ? {'Content-Length':req.headers['content-length']} : {}) } }, response => { res.writeHead(response.statusCode, { 'Content-Type':'application/json', 'Cache-Control':'no-store' }); response.pipe(res); });
    upstream.on('error', () => { if (!res.headersSent) res.writeHead(503, { 'Content-Type':'application/json' }); res.end(JSON.stringify({error:'The local voice helper is starting. Try again in a moment.'})); }); req.pipe(upstream); return;
  }
  const files = { '/':'index.html', '/app.js':'app.js', '/app.css':'app.css', '/icon.png':'icon.png' };
  const file = files[url.pathname]; if (!file) { res.writeHead(404); res.end(); return; }
  const types = { '.html':'text/html; charset=utf-8', '.js':'text/javascript', '.css':'text/css', '.png':'image/png' };
  res.writeHead(200, { 'Content-Type':types[path.extname(file)], 'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff', 'Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' blob: data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'" }); fs.createReadStream(path.join(site,file)).pipe(res);
});
server.listen(4180,'127.0.0.1',()=>console.log('OpenRead design preview: http://127.0.0.1:4180'));
let closing=false; function close(){if(closing)return;closing=true;helper.kill('SIGINT');server.close(()=>process.exit());setTimeout(()=>process.exit(),1500).unref();}process.on('SIGINT',close);process.on('SIGTERM',close);
