// Standalone: npx tsx src/math-search-selftest.ts (also included by npm test).
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import sharp from "sharp";
import { normalizeMathSearch } from "./math-search.js";
import { buildMcpServer } from "./mcp.js";
import { Store } from "./store.js";

for (const [left, right] of [
  ["x²", "x^2"], ["x²", "x^{2}"], ["x⁻¹²", "x^{-12}"],
  ["H₂O", "H_{2}O"], ["xₙ₊₁", "x_{n+1}"], ["xᵃᵇ", "x^{ab}"],
  ["xᵢ", "x_i"], ["xⁿ", "x^n"], ["xₓ", "x_x"],
  ["2πrh", "2\\pi r h"], ["a × b · c", "a\\times b\\cdot c"],
  ["\\frac{1}{2}", "1/2"], ["\\dfrac{\\frac{a}{b}}{c}", "a/b/c"],
  ["\\left( X^{2} \\right)", "(x²)"],
]) assert.equal(normalizeMathSearch(left), normalizeMathSearch(right), `${left} should match ${right}`);
assert.notEqual(normalizeMathSearch("x2"), normalizeMathSearch("x²"), "ordinary digits are not exponents");
assert.equal(normalizeMathSearch(" \n {} "), "");
console.log("math search normalization passed (Unicode scripts, pi, multiplication, nested fractions)");

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "claudebook-math-search-"));
const client = new Client({ name: "math-search-selftest", version: "0" });
let server: ReturnType<typeof buildMcpServer> | undefined;
try {
  let store = new Store(dir);
  const notebook = store.listNotebooks()[0], pageId = notebook.pages[0].id;
  const region = { x: 100, y: 200, w: 400, h: 80 };
  const vision = { text: "21rh+ 4T42", x: 110, y: 210, w: 300, h: 50 };
  const png = await sharp({ create: { width: 1000, height: 1414, channels: 4, background: "white" } }).png().toBuffer();
  store.saveSnapshot(pageId, png, [vision], 8);
  server = buildMcpServer(store);
  const [serverTransport, clientTransport] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  async function call(name: string, args: Record<string, unknown> = {}, error = false) {
    const result = await client.callTool({ name, arguments: args });
    assert.equal(Boolean(result.isError), error, `${name}: ${JSON.stringify(result.content).slice(0, 300)}`);
    return (result.content as { type: string; text?: string }[]).filter(c => c.type === "text").map(c => c.text).join("\n");
  }
  const text = "2πrh + 4πr²", latex = "2\\pi r h + 4\\pi r^2";
  const saved = JSON.parse(await call("set_transcript", { region, text, latex }));
  assert.equal(saved.page_id, pageId);
  assert.equal(saved.transcript.source, "claude");
  const id = saved.transcript.id;
  for (const query of ["2πrh", "2\\pi r h", "4pir^2"]) {
    const results = JSON.parse(await call("search_notes", { query })).results;
    assert(results.some((r: any) => r.pageId === pageId && r.source === "claude" && r.transcript.id === id && r.stale === false), query);
  }
  const described = await call("get_current_page", { grid: false });
  assert(described.includes("Claude's transcripts (x, y, w, h):") && described.includes(text));
  assert(!described.includes(vision.text), "covered raw Vision box should be hidden");
  store.saveSnapshot(pageId, png, [vision], 8);
  assert.equal(store.findPage(pageId)!.page.transcripts[0].stale, false, "same-count snapshot preserves reading");
  store.saveDrawing(pageId, Buffer.from("test ink"), 8);
  assert.equal(store.findPage(pageId)!.page.transcripts[0].stale, false, "same-count drawing preserves reading");
  store.saveSnapshot(pageId, png, [vision], 9);
  assert.equal(store.findPage(pageId)!.page.transcripts[0].stale, true);
  const stale = await call("get_current_page", { grid: false });
  assert(stale.includes("stale: ink may have changed") && stale.includes(vision.text), "stale transcript should reveal raw Vision");
  assert(JSON.parse(await call("search_notes", { query: "4pir^2" })).results.some((r: any) => r.stale === true));
  const replaced = JSON.parse(await call("set_transcript", { page_id: pageId, region, text, latex }));
  assert.equal(replaced.transcript.id, id);
  assert.equal(replaced.transcript.stale, false);
  assert.equal(store.findPage(pageId)!.page.transcripts.length, 1, "same region replaces old reading");
  store.saveDrawing(pageId, Buffer.from("changed ink"), 10);
  assert.equal(store.findPage(pageId)!.page.transcripts[0].stale, true, "drawing upload invalidates before snapshot arrives");
  await call("set_transcript", { page_id: pageId, region, text, latex });
  store.saveSnapshot(pageId, png, [vision], 10);
  assert.equal(store.findPage(pageId)!.page.transcripts[0].stale, false, "snapshot after drawing must not invalidate refreshed reading");
  await call("set_transcript", { page_id: "missing", region, text }, true);
  await call("set_transcript", { region: { ...region, x: 999 }, text }, true);
  assert.equal(store.findPage(pageId)!.page.transcripts.length, 1, "invalid requests leave readings untouched");

  // Show alternatives/confidence, preserve partial overlaps, and filter zooms.
  const other = { text: "raw low line", alts: ["raw low line", "unique × alternate", "third candidate"], confidence: 0.4, x: 600, y: 600, w: 200, h: 40 };
  const partial = { text: "partial line", x: 90, y: 210, w: 50, h: 30 };
  store.saveSnapshot(pageId, png, [vision, other, partial], 10);
  const withAlts = await call("view_page", { page_id: pageId, grid: false });
  assert(withAlts.includes("low confidence, zoom in") && withAlts.includes("unique × alternate"));
  assert(withAlts.includes(partial.text), "partial coverage must not hide line");
  assert(!withAlts.includes(vision.text));
  const altResults = JSON.parse(await call("search_notes", { query: "unique * alternate" })).results;
  assert(altResults.some((r: any) => r.source === "vision" && r.box.text === other.text));
  const zoomed = await call("view_page", { grid: false, zoom: region });
  assert(zoomed.includes(text) && !zoomed.includes(other.text));
  const elsewhere = await call("view_page", { grid: false, zoom: { x: 600, y: 600, w: 250, h: 100 } });
  assert(!elsewhere.includes("Claude's transcripts") && elsewhere.includes(other.text));
  assert.deepEqual(store.searchNotes("{}"), []);

  const copy = store.duplicatePages([pageId]).pages[0];
  assert.notEqual(copy.transcripts[0].id, id);
  copy.transcripts[0].region.x = 101;
  assert.equal(store.findPage(pageId)!.page.transcripts[0].region.x, 100, "duplicate regions are independent");
  store.setTranscript(copy.id, copy.transcripts[0].region, "copy only");
  assert.equal(store.findPage(pageId)!.page.transcripts[0].text, text);

  const counts = store.createNotebook("count transitions", 5).pages;
  store.saveSnapshot(counts[0].id, png, [], 0);
  store.setTranscript(counts[0].id, region, "zero");
  store.saveSnapshot(counts[0].id, png, [], 0);
  assert.equal(counts[0].transcripts[0].stale, false, "zero is a known count");
  store.saveSnapshot(counts[0].id, png, [], 1);
  assert.equal(counts[0].transcripts[0].stale, true, "zero to one invalidates");
  store.setTranscript(counts[1].id, region, "unknown");
  store.saveSnapshot(counts[1].id, png, [], 1);
  assert.equal(counts[1].transcripts[0].stale, true, "unknown to known invalidates");
  store.saveSnapshot(counts[2].id, png, [], 1);
  store.setTranscript(counts[2].id, region, "known");
  store.saveSnapshot(counts[2].id, png);
  assert.equal(counts[2].transcripts[0].stale, true, "known to unknown snapshot invalidates");
  store.setTranscript(counts[3].id, region, "unknown twice");
  store.saveDrawing(counts[3].id, Buffer.from("ink"));
  assert.equal(counts[3].transcripts[0].stale, true, "unknown drawing invalidates");
  store.saveSnapshot(counts[4].id, png, [], 1);
  store.setTranscript(counts[4].id, region, "sticky stale");
  store.saveSnapshot(counts[4].id, png, [], 2);
  store.saveSnapshot(counts[4].id, png, [], 1);
  assert.equal(counts[4].transcripts[0].stale, true, "returning to original count cannot clear stale");

  await client.close();
  await server.close();
  store = new Store(dir);
  assert.equal(store.findPage(pageId)!.page.transcripts[0].id, id, "transcripts persist on restart");
  assert.equal(store.findPage(copy.id)!.page.transcripts[0].text, "copy only");
  assert.equal(store.findPage(counts[4].id)!.page.transcripts[0].stale, true);
  const oldDb = JSON.parse(fs.readFileSync(path.join(dir, "db.json"), "utf8"));
  delete oldDb.notebooks[0].pages[0].transcripts;
  fs.writeFileSync(path.join(dir, "db.json"), JSON.stringify(oldDb));
  assert.deepEqual(new Store(dir).findPage(pageId)!.page.transcripts, [], "old databases load without transcripts");
  console.log("maths OCR/transcript MCP selftest passed (search, visibility, snapshots/drawings, staleness, persistence, duplicates, old databases)");
} finally {
  await client.close();
  await server?.close();
  fs.rmSync(dir, { recursive: true, force: true });
}
