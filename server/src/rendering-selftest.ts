// Math layout, text fallbacks, arrowheads, per-item warnings and the notebook/page tools.
import assert from "node:assert/strict";
import sharp from "sharp";
import WebSocket from "ws";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { pathBounds, pathEnds } from "./geometry.js";
import { renderHandwriting } from "./handwriting.js";
import { itemBBox, itemToSvg, offPageWarning, prepareBatch, prepareItems, translateItem, type Item } from "./items.js";
import { renderMath } from "./math.js";

const near = (actual: number, expected: number, tolerance = 0.05) => assert.ok(Math.abs(actual - expected) < tolerance, `${actual} != ${expected}`);

// Tall and stretchy math: the ink stays inside the box and the box starts exactly at x,y.
for (const latex of [
  "\\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix}", "\\begin{bmatrix} a \\\\ b \\\\ c \\end{bmatrix}", "\\frac{\\frac{a}{b}}{\\frac{c}{d}}",
  "A \\xrightarrow[below]{above} B", "A \\xleftarrow[b]{a} B", "\\ce{A ->[above][below] B}", "\\oint \\vec{B} \\cdot d\\vec{l}", "\\vec{l}",
  "\\left\\| x \\right\\|", "\\begin{array}{|c|c|} \\hline a & b \\\\ \\hline c & d \\\\ \\hline \\end{array}",
]) {
  const m = renderMath(latex, 100, 200, 36), ink = pathBounds(m.d);
  assert.ok(ink.x >= 100 - 0.05 && ink.y >= 200 - 0.05, `${latex} pokes above/left of its box: ${JSON.stringify(ink)}`);
  assert.ok(ink.x + ink.w <= 100 + m.w + 0.05 && ink.y + ink.h <= 200 + m.h + 0.05, `${latex} pokes out of its box`);
  assert.doesNotMatch(m.d, /[a-zSTA]/, `${latex}: outline should be absolute with no shorthand or arcs`);
  const [item] = prepareItems([{ type: "math", latex, x: 100, y: 200 }]), box = itemBBox(item);
  near(box.x, 100); near(box.y, 200);
}
// The vmatrix bars span the matrix: about as tall as the box, not twice it.
const vm = renderMath("\\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix}", 0, 0, 36);
near(pathBounds(vm.d).h, vm.h, 1.5);

// Table borders are lines: the middle of a cell stays paper-white.
const table = renderMath("\\begin{array}{|c|c|} \\hline a & b \\\\ \\hline c & d \\\\ \\hline \\end{array}", 0, 0, 72);
const raster = await sharp(Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${Math.ceil(table.w)}" height="${Math.ceil(table.h)}"><rect width="100%" height="100%" fill="white"/><path d="${table.d}" fill="black"/></svg>`)).raw().toBuffer({ resolveWithObject: true });
const dark = (x: number, y: number) => raster.data[(y * raster.info.width + x) * raster.info.channels] < 128;
// Along a row through the top cells (above the letters): left frame, middle rule, right frame, and paper between.
const row = Math.round(raster.info.height * 0.08);
let runs = 0;
for (let x = 0; x < raster.info.width; x++) if (dark(x, row) && (x === 0 || !dark(x - 1, row))) runs++;
assert.equal(runs, 3, "array cells must be outlined, not filled");

// MathJax throws TexError objects, which are not Error instances, so match on the message.
const texError = (pattern: RegExp) => (e: unknown) => pattern.test((e as { message: string }).message);
assert.throws(() => renderMath("\\badcommand x", 0, 0), texError(/Undefined control sequence \\badcommand/));
assert.throws(() => renderMath("\\frac{1}{", 0, 0), texError(/Missing close brace/));

// Text: Greek and maths symbols come from a handwriting font, arrows are drawn strokes.
for (const char of "ΩμθλπΔ∫√≈±→⇒⇌←↔↑↓é") assert.ok(renderHandwriting(char, 0, 0).d, `No outline for ${char}`);
assert.ok(renderHandwriting("→", 0, 0).w > renderHandwriting("-", 0, 0).w, "arrows get a proper advance");

// Fill without a color means no outline.
const [filled, outlinedRect] = prepareItems([{ type: "ellipse", center: [50, 50], rx: 20, fill: "#30A46C55" }, { type: "rect", x: 0, y: 0, w: 10, h: 10, fill: "#30A46C55", color: "#30A46C" }]);
assert.match(itemToSvg(filled), /stroke="none"/);
assert.doesNotMatch(itemToSvg(outlinedRect), /stroke="none"/);
assert.deepEqual(itemBBox(filled), { x: 30, y: 30, w: 40, h: 40 });

// Arrowheads and dashes on arrows, paths and SVG paths.
const [both, none, filledHead, path, svgArc, dashedArrow] = prepareItems([
  { type: "arrow", from: [100, 100], to: [300, 100], head: "both" },
  { type: "arrow", from: [100, 150], to: [300, 150], head: "none" },
  { type: "arrow", from: [100, 200], to: [300, 200], head_filled: true },
  { type: "path", points: [[100, 300], [200, 250], [300, 300]], head: "end" },
  { type: "svg", d: "M100,400 A100,100 0 0 1 300,400", head: "both", head_filled: true },
  { type: "arrow", from: [100, 500], to: [300, 500], dashed: true },
]);
assert.equal((both.head_d!.match(/M/g) ?? []).length, 2);
assert.equal(none.head_d, undefined);
assert.doesNotMatch(itemToSvg(none), /M\d+(\.\d+)?,\d+(\.\d+)?L\d+(\.\d+)?,\d+(\.\d+)?L/, "head:none draws a bare shaft");
assert.match(filledHead.head_d!, /Z$/);
near(itemBBox(both).x, 100 - 1.5); near(itemBBox(both).w, 203);
assert.match(itemToSvg(dashedArrow), /stroke-dasharray/);
const pathTip = path.head_d!.split("L")[1].split(",").map(Number);
near(pathTip[0], 300); near(pathTip[1], 300);
assert.doesNotMatch((svgArc as Item & { d: string }).d, /A/i, "arcs are stored as curves the iPad can parse");
const arcEnds = pathEnds((svgArc as Item & { d: string }).d)!;
near(arcEnds.end.angle, Math.PI / 2, 0.05); near(arcEnds.start.angle, Math.PI / 2, 0.05);
const movedArc = translateItem(svgArc, 10, 20);
assert.notEqual(movedArc.head_d, svgArc.head_d);
near(itemBBox(movedArc).x, itemBBox(svgArc).x + 10);

// Anchors put the named point at x,y and store the top-left.
const [centered, plain] = prepareItems([{ type: "text", x: 500, y: 500, text: "Hello", anchor: "center" }, { type: "text", x: 500, y: 500, text: "Hello" }]);
near(itemBBox(centered).x + itemBBox(centered).w / 2, 500, 1); near(itemBBox(centered).y + itemBBox(centered).h / 2, 500, 1);
assert.equal("anchor" in centered, false);
assert.equal(itemBBox(plain).x, 500);
const [bottomLeftMath] = prepareItems([{ type: "math", latex: "x^2", x: 100, y: 300, anchor: "bottom-left" }]);
near(itemBBox(bottomLeftMath).y + itemBBox(bottomLeftMath).h, 300);

// Per-item warnings: bad items are skipped, the rest are prepared.
const batch = prepareBatch([
  { type: "math", latex: "\\badcommand", x: 0, y: 0 },
  { type: "line", from: [0, 0], to: [10, 10], colour: "red" },
  { type: "arrow", from: [0, 0], to: [10, 10], dashed: true },
]);
assert.equal(batch.items.length, 1); assert.deepEqual(batch.indexes, [2]);
assert.match(batch.warnings[0].warning, /badcommand/);
assert.match(batch.warnings[1].warning, /"colour"/);
assert.equal(offPageWarning({ x: -2, y: 0, w: 10, h: 10 }), undefined, "strokes touching the edge are fine");
assert.match(offPageWarning({ x: 900, y: 0, w: 200, h: 10 })!, /right/);
console.log("[rendering] math boxes, table rules, text fallbacks, arrowheads, anchors and item warnings passed");

if (process.env.CLAUDEBOOK_SECRET) {
  const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787", secret = process.env.CLAUDEBOOK_SECRET;
  const client = new Client({ name: "rendering-selftest", version: "1" });
  const api = async (route: string, init: RequestInit = {}) => {
    const response = await fetch(`${base}/api${route}`, { ...init, headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json", ...init.headers } });
    assert.ok(response.ok, `${route}: HTTP ${response.status}`);
    return response;
  };
  await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${secret}`)));
  try {
    const notebook = await (await api("/notebooks", { method: "POST", body: JSON.stringify({ title: "Rendering self-test", pages: 2 }) })).json() as { id: string; pages: { id: string }[] };
    const [page_id, second] = notebook.pages.map((p) => p.id);
    const call = async (name: string, args: Record<string, unknown>, expectError = false) => {
      const result = await client.callTool({ name, arguments: args });
      assert.equal(!!result.isError, expectError, `${name}: ${JSON.stringify(result.content)}`);
      return (result.content as { type: string; text?: string }[])[0].text!;
    };
    const savedItems = async (id = page_id) => ((await (await api(`/pages/${id}/claude`)).json()) as { items: Item[] }).items;

    const drawn = JSON.parse(await call("draw_on_page", { page_id, items: [
      { type: "arrow", from: [100, 100], to: [300, 100], dashed: true, head: "both" },
      { type: "math", latex: "\\badcommand", x: 100, y: 200 },
      { type: "text", x: 100, y: 300, text: "ok", bogus: 1 },
      { type: "math", latex: "a + b + c + d + e + f + g + h + i + j + k", x: 800, y: 400 },
    ] }));
    assert.equal(drawn.items.length, 2);
    assert.deepEqual(drawn.warnings.map((w: { item: number }) => w.item), [1, 2, 3]);
    assert.match(drawn.warnings[0].warning, /badcommand/); assert.match(drawn.warnings[1].warning, /"bogus"/); assert.match(drawn.warnings[2].warning, /right edge/);
    assert.equal((await savedItems()).length, 2);

    const dry = JSON.parse(await call("draw_on_page", { page_id, dry_run: true, offset: [10, 20], items: [{ type: "rect", x: 100, y: 500, w: 50, h: 50 }] }));
    assert.match(dry.message, /Dry run/); near(dry.items[0].bbox.x, 108.5); near(dry.items[0].bbox.y, 518.5);
    assert.equal((await savedItems()).length, 2, "dry_run draws nothing");
    const shifted = JSON.parse(await call("draw_on_page", { page_id, offset: [10, 20], items: [{ type: "rect", x: 100, y: 500, w: 50, h: 50 }] }));
    assert.deepEqual(shifted.items[0].bbox, dry.items[0].bbox);

    const copied = JSON.parse(await call("copy_items", { page_id, ids: [drawn.items[0].id, "nope"], offset: [0, 50], target_page_id: second }));
    assert.equal(copied.items.length, 1); assert.notEqual(copied.items[0].id, drawn.items[0].id);
    near(copied.items[0].bbox.y, drawn.items[0].bbox.y + 50); assert.match(copied.message, /nope/);
    assert.equal((await savedItems(second))[0].head_d !== undefined, true);
    assert.equal((await savedItems()).length, 3, "copying leaves the source page alone");

    // Sync status reports the last upload and stroke count.
    assert.match(await call("view_page", { page_id, grid: false }), /No user ink has ever synced/);
    const png = await sharp({ create: { width: 10, height: 14, channels: 3, background: "white" } }).png().toBuffer();
    await api(`/pages/${page_id}/snapshot`, { method: "PUT", body: JSON.stringify({ png: png.toString("base64"), textBoxes: [], strokeCount: 7 }) });
    assert.match(await call("view_page", { page_id, grid: false }), /last synced .*s ago\)\. The page has 7 stroke/);
    await api(`/pages/${second}/drawing?strokes=0`, { method: "PUT", headers: { "Content-Type": "application/octet-stream" }, body: new Uint8Array([1]) });
    assert.match(await call("view_page", { page_id: second, grid: false }), /The user has no ink on this page/);

    // Notebook tools: rename right away, delete only after the iPad confirms, open_page over the websocket.
    assert.match(await call("rename_notebook", { notebook_id: notebook.id, title: "Renamed by Claude" }), /Renamed "Rendering self-test" to "Renamed by Claude"/);
    const events: { type: string; notebookId?: string; pageId?: string }[] = [];
    const ws = new WebSocket(`${base.replace(/^http/, "ws")}/live?token=${encodeURIComponent(secret)}`);
    await new Promise<void>((resolve) => ws.on("message", (m) => { const e = JSON.parse(String(m)); events.push(e); if (e.type === "hello") resolve(); }));
    await call("open_page", { notebook_id: notebook.id, page_number: 2 });
    await call("open_page", { notebook_id: notebook.id, page_number: 9 }, true);
    await call("delete_notebook", { notebook_id: notebook.id });
    await new Promise((resolve) => setTimeout(resolve, 300));
    ws.close();
    assert.ok(events.some((e) => e.type === "openPage" && e.pageId === second));
    assert.ok(events.some((e) => e.type === "deleteRequest" && e.notebookId === notebook.id));
    const pending = await (await api(`/notebooks/${notebook.id}`)).json() as { deleteRequestedAt?: string; title: string };
    assert.ok(pending.deleteRequestedAt, "delete_notebook only asks"); assert.equal(pending.title, "Renamed by Claude");
    assert.match(await call("list_notebooks", {}), /waiting for the user to confirm deletion/);
    await api(`/notebooks/${notebook.id}/delete-request`, { method: "DELETE" });
    assert.equal((await (await api(`/notebooks/${notebook.id}`)).json() as { deleteRequestedAt?: string }).deleteRequestedAt, undefined);
    await api(`/notebooks/${notebook.id}`, { method: "DELETE" });
    console.log("[rendering MCP] warnings, dry_run, offset, copy_items, sync status, rename, delete request and open_page passed");
  } finally {
    await client.close();
  }
}
