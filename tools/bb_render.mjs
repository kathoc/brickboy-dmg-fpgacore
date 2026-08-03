// Render flat / arbitrary native frames through brickboy's OWN display pipeline.
//
// Drives the ?renderfarm=1 harness in brickboy's dist build, which is the same
// six-pass WebGL chain the app puts on screen - so the pixels this writes are
// brickboy's pixels, not a reimplementation. Used to get ground-truth numbers
// for the Pocket port at the scale the Pocket actually runs (4x).
//
//   node bb_render.mjs <out.png> [scale] [shade|scene] [frames]
//
// shade: 0..3 renders a uniform field of that shade. Anything else is treated
// as a path to a raw u16le 160x144 frame.

import { createServer } from "node:http";
import { readFileSync, existsSync, writeFileSync } from "node:fs";
import { join, extname, dirname } from "node:path";
import { chromium } from "/home/sonohoka/.claude/tools/browser/node_modules/playwright/index.mjs";

const DIST = "/home/sonohoka/Playground/brickboy/dist";
const NW = 160, NH = 144;

const [outPath, scaleArg = "4", what = "1", framesArg = "8"] = process.argv.slice(2);
if (!outPath) {
  console.error("usage: bb_render.mjs <out.png> [scale] [shade|fb.raw] [frames]");
  process.exit(2);
}
const scale = Math.max(2, Math.min(6, Number(scaleArg) || 4));
const frames = Math.max(1, Number(framesArg) || 8);

let fb;
if (/^[0-3]$/.test(what)) {
  fb = new Uint16Array(NW * NH).fill(Number(what));
} else {
  fb = new Uint16Array(readFileSync(what).buffer.slice(0, NW * NH * 2));
}

// Repeat the frame so the persistence IIR settles before the one we keep.
const batch = new Uint8Array(frames * NW * NH * 2);
for (let i = 0; i < frames; i++) {
  batch.set(new Uint8Array(fb.buffer), i * NW * NH * 2);
}

const MIME = {
  ".html": "text/html", ".js": "text/javascript", ".css": "text/css",
  ".json": "application/json", ".png": "image/png", ".svg": "image/svg+xml",
  ".webmanifest": "application/manifest+json",
};
const srv = createServer((req, res) => {
  let p = new URL(req.url, "http://x").pathname;
  if (p === "/") p = "/index.html";
  const f = join(DIST, p);
  if (!existsSync(f) || !f.startsWith(DIST)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": MIME[extname(f)] ?? "application/octet-stream" });
  res.end(readFileSync(f));
});
await new Promise((r) => srv.listen(0, "127.0.0.1", r));
const port = srv.address().port;

const browser = await chromium.launch({
  // Same ladder render-lcd.mjs walks: try the real GPU first. SwiftShader
  // renders the same shaders, but its default framebuffer does not survive the
  // readPixels the harness does, so a software fallback comes back all black.
  args: ["--no-sandbox", "--disable-dev-shm-usage",
         "--use-angle=gl-egl", "--ignore-gpu-blocklist"],
});
const page = await browser.newPage();
await page.goto(`http://127.0.0.1:${port}/?renderfarm=1`);
await page.waitForFunction("!!window.__rf", null, { timeout: 30000 });

const info = await page.evaluate(([p, s]) => window.__rf.init(p, s), ["dmg", scale]);
console.error(`renderer: ${info.renderer}  canvas ${info.w}x${info.h}`);

const b64in = Buffer.from(batch).toString("base64");
const b64out = await page.evaluate((b) => window.__rf.renderBatch(b), b64in);
const px = Buffer.from(b64out, "base64");

const { w, h } = info;
const stride = w * h * 4;
const last = px.subarray((frames - 1) * stride, frames * stride);

// GL reads bottom-up; flip to image order and write a PNG via the page's canvas.
const flipped = Buffer.alloc(stride);
for (let y = 0; y < h; y++) {
  last.copy(flipped, y * w * 4, (h - 1 - y) * w * 4, (h - y) * w * 4);
}
const dataUrl = await page.evaluate(([b64, w, h]) => {
  const bin = atob(b64);
  const a = new Uint8ClampedArray(bin.length);
  for (let i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i);
  const c = document.createElement("canvas");
  c.width = w; c.height = h;
  c.getContext("2d").putImageData(new ImageData(a, w, h), 0, 0);
  return c.toDataURL("image/png");
}, [flipped.toString("base64"), w, h]);
writeFileSync(outPath, Buffer.from(dataUrl.split(",")[1], "base64"));
console.error(`wrote ${outPath}`);

await browser.close();
srv.close();
