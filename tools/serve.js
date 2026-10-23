// Local static server for the Cargo site. Binds 127.0.0.1, serves only site/.
const http = require("http"), fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, "..", "site"), PORT = +process.env.PORT || 5190;
const MT = { ".html": "text/html; charset=utf-8", ".json": "application/json", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".svg": "image/svg+xml" };
http.createServer((q, r) => {
  let u = decodeURIComponent(q.url.split("?")[0]); if (u.endsWith("/")) u += "index.html";
  const f = path.resolve(ROOT, "." + u);
  if (!f.startsWith(ROOT + path.sep)) { r.writeHead(403); return r.end("forbidden") }
  fs.readFile(f, (e, d) => { if (e) { r.writeHead(404); return r.end("not found") } r.writeHead(200, { "content-type": MT[path.extname(f)] || "application/octet-stream", "cache-control": "no-store" }); r.end(d) });
}).listen(PORT, "127.0.0.1", () => console.log("Cargo site: http://localhost:" + PORT + "/"));
