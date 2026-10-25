const http = require('node:http'); const fs = require('node:fs'); const path = require('node:path');
const root = path.resolve(__dirname, '../../app/website/dist');
const mime = { '.html':'text/html; charset=utf-8','.js':'text/javascript','.css':'text/css','.png':'image/png','.mp4':'video/mp4','.m4a':'audio/mp4','.txt':'text/plain','.xml':'application/xml' };
http.createServer((req,res) => {
  try {
    const pathname = decodeURIComponent(new URL(req.url,'http://127.0.0.1').pathname);
    const file = path.resolve(root, pathname === '/' ? 'index.html' : '.'+pathname);
    if (!file.startsWith(root+path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) { res.writeHead(404); res.end('Not found'); return; }
    const size = fs.statSync(file).size; const type=mime[path.extname(file)]||'application/octet-stream';
    const range = req.headers.range?.match(/^bytes=(\d+)-(\d*)$/);
    if (range) { const start=Number(range[1]),end=range[2]?Math.min(Number(range[2]),size-1):size-1; if(start>=size||start>end){res.writeHead(416,{'Content-Range':`bytes */${size}`});res.end();return;} res.writeHead(206,{'Content-Type':type,'Content-Length':end-start+1,'Content-Range':`bytes ${start}-${end}/${size}`,'Accept-Ranges':'bytes'});fs.createReadStream(file,{start,end}).pipe(res);return; }
    res.writeHead(200,{'Content-Type':type,'Content-Length':size,'Cache-Control':'no-store','Accept-Ranges':'bytes'});fs.createReadStream(file).pipe(res);
  } catch { res.writeHead(400);res.end('Bad request'); }
}).listen(4190,'127.0.0.1',()=>console.log('OpenRead public website preview: http://127.0.0.1:4190'));
