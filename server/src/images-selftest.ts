import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import { execFileSync } from "node:child_process";
import sharp from "sharp";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { savePdf, compileTypst } from "./pdf.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { Store } from "./store.js";
import { buildMcpServer } from "./mcp.js";
import { placeImage, imageAnchor } from "./images.js";
import { imageDir, imagePath, MAX_IMAGE_BYTES, normalizeImage, sweepImages } from "./image-assets.js";
import { downloadBytes, publicAddress } from "./download.js";
import { claudeLayerSvg, renderPage } from "./render.js";
import { itemBBox, prepareBatch, prepareItems } from "./items.js";

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "claudebook-images-"));
const store = new Store(dir), page = store.listNotebooks()[0].pages[0];
const png = await sharp({ create: { width: 120, height: 60, channels: 3, background: "#ed1818" } }).png().toBuffer();
const data = png.toString("base64");
const close = (a: number, b: number) => assert.ok(Math.abs(a - b) < 0.5, `${a} != ${b}`);
const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
const server = buildMcpServer(store), client = new Client({ name: "images-selftest", version: "1" });
await server.connect(serverTransport); await client.connect(clientTransport);
try {
  const listed = await client.listTools();
  assert.ok(listed.tools.some(t => t.name === "place_image"));
  const schema = listed.tools.find(t => t.name === "place_image")!.inputSchema;
  assert.equal(schema.type, "object");
  const check = (node: unknown) => {
    if (!node || typeof node !== "object") return;
    const value = node as Record<string, unknown>;
    assert.ok(!("oneOf" in value)); assert.ok(!Array.isArray(value.items));
    if (value.type === "array") assert.ok(value.items);
    Object.values(value).forEach(check);
  };
  check(schema);
  const tool = await client.callTool({ name: "place_image", arguments: { x: 40, y: 60, w: 240, data } });
  assert.ok(!tool.isError, JSON.stringify(tool.content));
  const placed = JSON.parse((tool.content as { text: string }[])[0].text);
  assert.ok(placed.id); close(placed.bbox.x, 40); close(placed.bbox.y, 60); close(placed.bbox.w, 240); close(placed.bbox.h, 120);

  const anchors = [[0, 0], [.5, 0], [1, 0], [0, .5], [.5, .5], [1, .5], [0, 1], [.5, 1], [1, 1]];
  for (let i = 0; i < imageAnchor.options.length; i++) {
    const anchor = imageAnchor.options[i];
    const { item, bbox } = await placeImage(store, { x: 400, y: 500, w: 240, anchor, data });
    close(bbox.x + bbox.w * anchors[i][0], 400); close(bbox.y + bbox.h * anchors[i][1], 500);
    assert.equal(item.type, "image"); close(bbox.w / bbox.h, 2);
  }
  assert.equal(fs.readdirSync(imageDir(store)).length, 1, "identical normalized bytes deduplicate");
  const output = await sharp(await renderPage(store, page)).raw().toBuffer({ resolveWithObject: true });
  const offset = (80 * output.info.width + 80) * output.info.channels;
  assert.ok(output.data[offset] > 200 && output.data[offset + 1] < 60, "raster output contains the red image");
  assert.match(claudeLayerSvg(page, store), /data:image\/jpeg;base64,/);

  const source = store.newPage("blank");
  store.insertPages(store.listNotebooks()[0].id, [source]);
  store.addClaudeItems(source.id, prepareItems([{ type: "rect", x: 100, y: 200, w: 200, h: 100, fill: "#ed1818" }]));
  const crop = await placeImage(store, { x: 50, y: 300, w: 200, source: { page_id: source.id, region: { x: 110, y: 210, w: 180, h: 80 } } });
  close(crop.bbox.x, 50); close(crop.bbox.y, 300); close(crop.bbox.w / crop.bbox.h, 180 / 80);
  const smallCrop = await placeImage(store, { x: 50, y: 300, w: 100, source: { page_id: source.id, region: { x: 110, y: 210, w: 20, h: 10 } } });
  close(smallCrop.bbox.w / smallCrop.bbox.h, 2);
  let pdfTools = true;
  try { for (const binary of ["pdfinfo", "pdftoppm"]) execFileSync(binary, ["-v"], { stdio: "ignore" }); }
  catch { pdfTools = false; }
  if (pdfTools) {
    // A PDF figure must go through renderPage's rasterizer, exactly as an imported file does.
    const pdf = await savePdf(store, await compileTypst('#set page(width: 600pt, height: 300pt, margin: 0pt)\n#rect(width: 600pt, height: 300pt, fill: red, stroke: none)'));
    const imported = store.addPdfPages(pdf.file, pdf.pages, "Image crop PDF").notebook.pages[0];
    const placed = await placeImage(store, { x: 20, y: 30, w: 200, source: { page_id: imported.id, region: { x: 100, y: 500, w: 400, h: 100 } } });
    close(placed.bbox.w / placed.bbox.h, 4);
    const pixels = await sharp(await renderPage(store, page)).removeAlpha().raw().toBuffer({ resolveWithObject: true });
    const position = (50 * pixels.info.width + 50) * pixels.info.channels;
    assert.ok(pixels.data[position] > 200 && pixels.data[position + 1] < 70, "PDF figure crop renders red");
    store.removeClaudeItemsByIds(page.id, [placed.item.id]);
    console.log("[images PDF] crop of a real imported PDF page passed");
  }
  const strip = await placeImage(store, { x: 50, y: 300, w: 1, source: { page_id: source.id, region: { x: 110, y: 0, w: 1, h: 1414 } } });
  if (strip.item.type !== "image") throw new Error("Missing strip image");
  const stripMeta = await sharp(imagePath(store, strip.item.file)).metadata();
  assert.ok(stripMeta.height! <= 2048 && stripMeta.width! <= 2048);
  assert.ok((await placeImage(store, { x: 995, y: 1400, w: 100, data })).warnings.length);
  assert.match(prepareBatch([{ type: "image", x: 0, y: 0 }]).warnings[0].warning, /place_image/);

  for (const address of ["127.0.0.1", "10.2.3.4", "100.64.1.1", "169.254.0.1", "172.16.1.1", "192.168.1.2", "0.0.0.0", "224.1.1.1", "::1", "fc00::1", "fe80::1", "::ffff:127.0.0.1", "2002:7f00:1::", "2001:db8::1"]) assert.equal(publicAddress(address), false, address);
  assert.equal(publicAddress("8.8.8.8"), true); assert.equal(publicAddress("2606:4700:4700::1111"), true);
  await assert.rejects(() => placeImage(store, { x: 0, y: 0, url: "https://127.0.0.1/test.png" }), /private\/local/);
  await assert.rejects(() => placeImage(store, { x: 0, y: 0, data: Buffer.from("not an image").toString("base64") }), /Cannot decode image/);
  await assert.rejects(() => normalizeImage(Buffer.alloc(20 * 1024 * 1024)), /15MB/);
  await assert.rejects(() => placeImage(store, { x: 0, y: 0, url: "https://example.com/x", data }), /exactly one/);
  await assert.rejects(() => placeImage(store, { x: 0, y: 0 }), /exactly one/);
  await assert.rejects(() => placeImage(store, { x: 0, y: 0, data: "data:image/png,broken" }), /base64/);
  const badTool = await client.callTool({ name: "place_image", arguments: { x: 0, y: 0, data, url: "https://example.com/image.png" } });
  assert.ok(badTool.isError);

  const local = http.createServer((req, res) => {
    if (req.url === "/redirect") { res.writeHead(302, { Location: "https://127.0.0.2/private" }); res.end(); }
    else if (req.url === "/large") { res.writeHead(200, { "Content-Length": 20 * 1024 * 1024 }); res.end(); }
    else if (req.url === "/stream-large") { res.writeHead(200); res.end(Buffer.alloc(MAX_IMAGE_BYTES + 1)); }
    else { res.writeHead(200, { "Content-Type": "image/png" }); res.end(png); }
  });
  await new Promise<void>(resolve => local.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${(local.address() as { port: number }).port}`;
  const download = (value: string) => downloadBytes(value, { label: "Image", maxBytes: MAX_IMAGE_BYTES, testOnlyAllowLocalHttp: true });
  try {
    const fromUrl = await placeImage(store, { x: 123, y: 234, w: 80, url: `${url}/image` }, download);
    close(fromUrl.bbox.x, 123); close(fromUrl.bbox.y, 234); close(fromUrl.bbox.h, 40);
    await assert.rejects(() => download(`${url}/large`), /15MB/);
    await assert.rejects(() => download(`${url}/stream-large`), /15MB/);
    await assert.rejects(() => download(`${url}/redirect`), /private\/local/);
    await assert.rejects(() => downloadBytes(`${url}/image`, { maxBytes: MAX_IMAGE_BYTES, label: "Image" }), /Only https/);
  } finally { local.closeAllConnections(); await new Promise<void>(resolve => local.close(() => resolve())); }

  // Rotation, placement, copies, moves, groups and undo keep their backing resource.
  const image = page.claudeLayer.find(i => i.type === "image")!;
  assert.equal(image.type, "image");
  if (image.type !== "image") throw new Error("Missing image");
  const dest = imagePath(store, image.file);
  const copied = store.copyClaudeItems(page.id, [image.id], 10, 20, source.id)[0];
  const moved = store.moveClaudeItems(source.id, [copied.id], 20, 30)[0];
  close(itemBBox(moved).x, itemBBox(image).x + 30);
  store.removeClaudeItems(page.id);
  assert.ok(fs.existsSync(dest), "copy on another page keeps image");
  store.removeClaudeItems(source.id, 1);
  assert.ok(!fs.existsSync(dest), "undoing last reference sweeps backing image");
  assert.equal(fs.readdirSync(imageDir(store)).length, 0);
  const restored = await placeImage(store, { x: 400, y: 500, w: 100, rotation: 90, data, group: "image-group" });
  close(restored.bbox.w, 50); close(restored.bbox.h, 100);
  const duplicate = store.duplicatePages([page.id]);
  store.removeClaudeItemsByIds(page.id, [], "image-group");
  assert.equal(fs.readdirSync(imageDir(store)).length, 1);
  store.deletePages(duplicate.notebook.id, duplicate.pages.map(p => p.id));
  assert.equal(fs.readdirSync(imageDir(store)).length, 0);
  fs.writeFileSync(dest, png);
  new Store(dir); // startup removes a stale orphan too
  assert.ok(!fs.existsSync(dest));
  sweepImages(store);

  const fitPage = store.newPage("blank"); store.insertPages(store.listNotebooks()[0].id, [fitPage]);
  for (const [i, fit] of (["contain", "cover", "stretch"] as const).entries()) {
    await placeImage(store, { page_id: fitPage.id, x: 100 + i * 200, y: 100, w: 100, h: 100, fit, data });
  }
  await placeImage(store, { page_id: fitPage.id, x: 700, y: 100, w: 100, h: 100, fit: "stretch", opacity: 0.5, data });
  const fits = await sharp(await renderPage(store, fitPage)).removeAlpha().raw().toBuffer({ resolveWithObject: true });
  const green = (x: number, y: number) => fits.data[(y * fits.info.width + x) * fits.info.channels + 1];
  assert.ok(green(110, 110) > 240, "contain leaves space above image");
  assert.ok(green(110, 140) < 60, "contain preserves image ratio");
  assert.ok(green(310, 110) < 60, "cover fills its clipped box");
  assert.ok(green(510, 110) < 60, "stretch fills its box");
  assert.ok(green(710, 110) > 120 && green(710, 110) < 170, "opacity composites over paper");
  const alpha = await normalizeImage(await sharp({ create: { width: 2500, height: 500, channels: 4, background: "#0000ff88" } }).png().toBuffer());
  assert.ok(alpha.file.endsWith(".png")); assert.equal(alpha.w, 2048); assert.equal(alpha.h, 410);
  const exif = await normalizeImage(await sharp(png).jpeg().withMetadata({ orientation: 6 }).toBuffer());
  assert.equal(exif.w, 60); assert.equal(exif.h, 120);
  const svg = await normalizeImage(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40"><rect width="80" height="40" fill="blue"/></svg>'));
  assert.equal(svg.w, 80); assert.equal(svg.h, 40);
  await assert.rejects(() => normalizeImage(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40"><image href="file:///private.png" width="80" height="40"/></svg>')), /external resources/);
  console.log("[images] data, all anchors, exact page crops, local URL, guard/redirect/size failures, normalization, PNG/SVG renders, dedupe, copy/move/erase/undo and sweep passed");
} finally { await client.close(); await server.close(); fs.rmSync(dir, { recursive: true, force: true }); }

if (process.env.CLAUDEBOOK_SECRET) {
  const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787", secret = process.env.CLAUDEBOOK_SECRET;
  const headers = { Authorization: `Bearer ${secret}`, "Content-Type": "application/json" };
  const remote = new Client({ name: "images-http-selftest", version: "1" });
  await remote.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${secret}`)));
  const response = await fetch(`${base}/api/notebooks`, { method: "POST", headers, body: JSON.stringify({ title: "Image HTTP self-test", pages: 2 }) });
  assert.ok(response.ok);
  const notebook = await response.json() as { id: string; pages: { id: string }[] };
  try {
    const page_id = notebook.pages[0].id;
    const placed = await remote.callTool({ name: "place_image", arguments: { page_id, x: 10, y: 20, w: 240, data, alt: "Red image", group: "image-http" } });
    assert.ok(!placed.isError, JSON.stringify(placed.content));
    const id = JSON.parse((placed.content as { text: string }[])[0].text).id;
    const items = await (await fetch(`${base}/api/pages/${page_id}/claude`, { headers })).json() as { items: { id: string; file: string }[] };
    const image = items.items.find(i => i.id === id)!;
    const asset = `${base}/api/images/${image.file}`;
    assert.equal((await fetch(asset)).status, 401);
    const served = await fetch(asset, { headers });
    assert.ok(served.ok); assert.match(served.headers.get("cache-control") ?? "", /private/);
    assert.equal((await sharp(Buffer.from(await served.arrayBuffer())).metadata()).width, 120);
    const svg = await (await fetch(`${base}/api/pages/${page_id}/claude.svg`, { headers })).text();
    assert.match(svg, /data:image\/jpeg;base64,/);
    const copy = await remote.callTool({ name: "place_image", arguments: { page_id: notebook.pages[1].id, x: 300, y: 400, w: 120, source: { page_id, region: { x: 10, y: 20, w: 240, h: 120 } } } });
    assert.ok(!copy.isError, JSON.stringify(copy.content));
    const view = await remote.callTool({ name: "view_page", arguments: { page_id: notebook.pages[1].id, grid: false } });
    assert.ok((view.content as { type: string }[]).some(c => c.type === "image"));
    const erased = await remote.callTool({ name: "erase_my_drawings", arguments: { page_id, group: "image-http" } });
    assert.ok(!erased.isError); assert.equal((await fetch(asset, { headers })).status, 404);
    console.log("[images HTTP/MCP] authenticated assets, standalone SVG, cross-page crop, view_page and last-reference erase passed");
  } finally {
    await remote.close();
    await fetch(`${base}/api/notebooks/${notebook.id}`, { method: "DELETE", headers });
  }
}

