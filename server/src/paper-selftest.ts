import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import sharp from "sharp";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { buildMcpServer } from "./mcp.js";
import { Store, PAGE_W, PAGE_H, type StoreEvent } from "./store.js";
import { backgrounds, papers, paperColor } from "./paper.js";
import { adaptPaperInk } from "./paper-ink.js";
import { renderPage } from "./render.js";

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "claudebook-paper-"));
const store = new Store(dir), notebook = store.createNotebook("Paper tests", 3);
store.setView(notebook.id, notebook.pages[0].id);
const server = buildMcpServer(store), client = new Client({ name: "paper-selftest", version: "1" });
const [a, b] = InMemoryTransport.createLinkedPair();
await server.connect(b); await client.connect(a);
const events: StoreEvent[] = []; store.on(event => events.push(event));
const call = async (name: string, args: Record<string, unknown>, error = false) => {
  const result = await client.callTool({ name, arguments: args });
  assert.equal(!!result.isError, error, JSON.stringify(result.content));
  return result.content as Array<{ type: string; text?: string; data?: string }>;
};
try {
  for (const background of backgrounds) for (const paper of papers) {
    const png = await renderPage(store, store.newPage(background, paper));
    const metadata = await sharp(png).metadata(); assert.equal(metadata.width, 1000); assert.equal(metadata.height, 1414);
  }
  console.log(`[paper] ${backgrounds.length} templates x ${papers.length} colours rendered`);
  // Legacy snapshots deliberately retain the old server palette (historically different from iPad).
  for (const background of ["blank", "lined", "grid", "dotted"] as const) {
    const lines: string[] = [];
    if (background === "lined") for (let y = 120; y < PAGE_H - 40; y += 40) lines.push(`<line x1="40" y1="${y}" x2="${PAGE_W - 40}" y2="${y}" stroke="#C9D7E8" stroke-width="1.5"/>`);
    if (background === "grid") {
      for (let x = 25; x < PAGE_W; x += 25) lines.push(`<line x1="${x}" y1="0" x2="${x}" y2="${PAGE_H}" stroke="#E3EAF2" stroke-width="1"/>`);
      for (let y = 25; y < PAGE_H; y += 25) lines.push(`<line x1="0" y1="${y}" x2="${PAGE_W}" y2="${y}" stroke="#E3EAF2" stroke-width="1"/>`);
    }
    if (background === "dotted") for (let x = 25; x < PAGE_W; x += 25) for (let y = 25; y < PAGE_H; y += 25) lines.push(`<circle cx="${x}" cy="${y}" r="1.4" fill="#C9D2DC"/>`);
    const before = await sharp(Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1414" viewBox="0 0 1000 1414"><rect width="100%" height="100%" fill="#ffffff"/>${lines.join("")}</svg>`)).composite([]).png().toBuffer();
    const expected = await sharp(before).png().toBuffer();
    assert.deepEqual(await renderPage(store, store.newPage(background)), expected, `${background}: preserve old bytes`);
  }
  await call("set_page_background", { background: "cornell", paper: "black" });
  assert.equal(notebook.pages[0].background, "cornell"); assert.equal(notebook.pages[0].paper, "black");
  assert.ok(events.some(event => event.type === "notebook" && event.notebookId === notebook.id));
  await call("set_page_background", { page_ids: notebook.pages.slice(1).map(p => p.id), background: "hex", paper: "white" });
  assert.deepEqual(notebook.pages.map(p => p.background), ["cornell", "hex", "hex"]);
  await call("set_page_background", { notebook_id: notebook.id, all_pages: true, paper: "slate" });
  assert.ok(notebook.pages.every(p => p.paper === "slate"));
  const before = JSON.stringify(notebook.pages);
  await call("set_page_background", { page_ids: [notebook.pages[0].id, "missing"], paper: "white" }, true);
  assert.equal(JSON.stringify(notebook.pages), before, "selection validation is atomic");
  await call("set_page_background", { background: "invalid" }, true);
  await call("set_page_background", { paper: "invalid" }, true);
  await call("set_page_background", {}, true);
  await call("set_page_background", { page_ids: [notebook.pages[0].id], all_pages: true, paper: "white" }, true);
  await call("set_page_background", { page_ids: [notebook.pages[0].id], background: "blank", paper: "black" });
  const view = await call("view_page", { page_id: notebook.pages[0].id, grid: false });
  assert.match(view[0].text!, /Paper: black/);
  const pixel = await sharp(Buffer.from(view.find(c => c.type === "image")!.data!, "base64")).extract({ left: 500, top: 500, width: 1, height: 1 }).removeAlpha().raw().toBuffer();
  assert.deepEqual([...pixel], [0, 0, 0]);
  await call("set_page_background", { page_ids: [notebook.pages[0].id], background: "cornell" });
  const description = await call("view_page", { page_id: notebook.pages[0].id, grid: false });
  assert.match(description[0].text!, /Cornell: cues x 0-300, notes x 300-1000, summary y 1150-1414/);
  await call("create_notebook", { title: "New graph", background: "graph", paper: "yellow" });
  const created = store.listNotebooks().find(n => n.title === "New graph")!;
  assert.equal(created.pages[0].paper, "yellow");
  await call("add_pages", { notebook_id: created.id, background: "music", paper: "cream" });
  assert.equal(created.pages[1].background, "music"); assert.equal(created.pages[1].paper, "cream");
  assert.equal(new Store(dir).getNotebook(created.id)!.pages[1].paper, "cream");
  assert.equal(paperColor("black"), "#000000");
  assert.equal(adaptPaperInk('<path stroke="black" fill="none"/>'), '<path stroke="#ffffff" fill="none"/>');
  await call("draw_on_page", { page_id: notebook.pages[0].id, items: [{ type: "rect", x: 400, y: 400, w: 100, h: 100, fill: "black" }] });
  const darkInk = await sharp(await renderPage(store, notebook.pages[0])).extract({ left: 450, top: 450, width: 1, height: 1 }).removeAlpha().raw().toBuffer();
  assert.ok(darkInk[0] > 210, "Claude black ink adapts to a light colour on dark paper");
  console.log("[paper MCP] current/list/all, broadcasts, atomic validation, black view_page, descriptions and persistence passed");
} finally {
  await client.close(); await server.close(); fs.rmSync(dir, { recursive: true, force: true });
}
