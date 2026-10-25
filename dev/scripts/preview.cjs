const http = require("node:http");
const fs = require("node:fs/promises");
const path = require("node:path");
const root = path.resolve(__dirname, "../..");
const types = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".png": "image/png" };
http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://127.0.0.1");
    const relative = url.pathname === "/" ? "dev/tests/fixtures/article/index.html" : decodeURIComponent(url.pathname).slice(1).replace(/^demo\//, "dev/tests/fixtures/article/");
    const file = path.resolve(root, relative);
    const allowed = ["dev/tests/fixtures/article", "extension"].some((folder) => file.startsWith(path.join(root, folder) + path.sep));
    if (!allowed) { res.writeHead(404); res.end(); return; }
    const data = await fs.readFile(file);
    res.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream", "Cache-Control": "no-store" });
    res.end(data);
  } catch { res.writeHead(404); res.end("Not found"); }
}).listen(4173, "127.0.0.1", () => console.log("OpenRead preview: http://127.0.0.1:4173"));
