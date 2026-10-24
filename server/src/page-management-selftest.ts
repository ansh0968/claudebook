import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import sharp from "sharp";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { Store, type Notebook, type Page } from "./store.js";
import { prepareItems, type Item } from "./items.js";

const png = await sharp({ create: { width: 20, height: 20, channels: 3, background: "#123456" } }).png().toBuffer();
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "claudebook-page-management-"));
try {
  let store = new Store(directory);
  for (const nb of [...store.listNotebooks()]) store.deleteNotebook(nb.id);
  assert.equal(store.listNotebooks().length, 0, "Deleting the last notebook must not create a replacement");
  store = new Store(directory);
  assert.equal(store.listNotebooks().length, 0, "A persisted empty library must stay empty after restart");
  const source = store.createNotebook("Original", 3), target = store.createNotebook("Destination", 1);
  const [first, second, third] = source.pages;
  first.pdf = { file: "immutable-source-pdf", page: 7 };
  store.saveSnapshot(first.id, png, [{ text: "Original handwriting", x: 20, y: 30, w: 40, h: 20 }], 2);
  store.saveDrawing(first.id, Buffer.from([1, 2, 3, 4]), 2);
  store.addDoubt(first.id, { x: 20, y: 30, w: 50, h: 30 });
  const axes = prepareItems([{ type: "axes", origin: [200, 500], xrange: [-1, 3], yrange: [-1, 3] }])[0];
  const plot = prepareItems([{ type: "plot", axes: axes.id, fn: "x^2" }], [axes])[0];
  store.addClaudeItems(first.id, [axes, plot]);
  store.setView(source.id, second.id);
  store.reorderPages(source.id, [third.id, second.id, first.id]);
  assert.equal(store.view().pageId, second.id);
  assert.equal(source.pages[2].pdf?.page, 7);
  assert.deepEqual(fs.readFileSync(store.snapshotPath(first.id)), png);
  const beforeInvalid = fs.readFileSync(path.join(directory, "db.json"), "utf8");
  for (const operation of [
    () => store.reorderPages(source.id, [first.id, first.id, third.id]),
    () => store.reorderPages(source.id, [first.id, second.id]),
    () => store.movePages([first.id, "missing-page"], target.id),
    () => store.movePages([first.id], target.id, 200),
    () => store.deletePages(source.id, [first.id, target.pages[0].id]),
    () => store.duplicatePages([first.id], "missing-notebook"),
  ]) { assert.throws(operation); assert.equal(fs.readFileSync(path.join(directory, "db.json"), "utf8"), beforeInvalid); }
  const copy = store.duplicatePages([first.id], target.id, 0).pages[0];
  assert.notEqual(copy.id, first.id); assert.deepEqual(copy.pdf, first.pdf);
  assert.deepEqual(copy.textBoxes, first.textBoxes);
  assert.deepEqual(fs.readFileSync(store.snapshotPath(copy.id)), png);
  assert.deepEqual(fs.readFileSync(store.drawingPath(copy.id)), Buffer.from([1, 2, 3, 4]));
  assert.notEqual(copy.claudeLayer[0].id, axes.id);
  const copiedPlot = copy.claudeLayer[1];
  assert.ok(copiedPlot.type === "plot"); assert.equal(copiedPlot.axes, copy.claudeLayer[0].id);
  assert.notEqual(copy.doubts[0].id, first.doubts[0].id); assert.equal(copy.doubts[0].pageId, copy.id);
  copy.textBoxes[0].text = "Independent copy";
  store.saveDrawing(copy.id, Buffer.from([9]));
  assert.equal(first.textBoxes[0].text, "Original handwriting");
  assert.deepEqual(fs.readFileSync(store.drawingPath(first.id)), Buffer.from([1, 2, 3, 4]));
  store.setView(source.id, first.id);
  store.movePages([first.id], target.id, 1);
  assert.equal(store.findPage(first.id)?.notebook.id, target.id);
  assert.equal(store.view().notebookId, target.id); assert.equal(store.view().pageId, first.id);
  assert.deepEqual(first.pdf, { file: "immutable-source-pdf", page: 7 });
  store.deletePages(target.id, [first.id]);
  assert.ok(!store.findPage(first.id)); assert.ok(!fs.existsSync(store.snapshotPath(first.id)) && !fs.existsSync(store.drawingPath(first.id)));
  assert.equal(store.view().pageId, target.pages[1].id, "Deleted current page should select its next surviving neighbor");
  store.deletePages(source.id, source.pages.map(p => p.id));
  assert.equal(source.pages.length, 0);
  store.insertPages(source.id, [store.newPage("lined")], -1);
  assert.equal(source.pages.length, 1);
  assert.throws(() => store.setView(target.id, source.pages[0].id), /belong/);
  store.movePages([copy.id], target.id, 0);
  assert.equal(target.pages[0].id, copy.id, "Same-notebook moves use insertion count after removal");
  const neighbors = store.createNotebook("Neighbors", 6), original = [...neighbors.pages];
  store.setView(neighbors.id, original[3].id);
  store.deletePages(neighbors.id, [original[0].id, original[3].id]);
  assert.equal(store.view().pageId, original[4].id, "Multi-delete must choose the next original surviving neighbor");
  console.log("[page management] empty libraries, identity-safe reorder/move, independent ink/PDF/item/doubt copies and invalid-request atomicity passed");
} finally { fs.rmSync(directory, { recursive: true, force: true }); }

if (process.env.CLAUDEBOOK_SECRET) {
  const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787", secret = process.env.CLAUDEBOOK_SECRET;
  const api = async (route: string, method = "GET", body?: unknown, status = 200) => {
    const response = await fetch(`${base}/api${route}`, { method, headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    assert.equal(response.status, status, `${method} ${route}: ${await response.clone().text()}`);
    return response;
  };
  const client = new Client({ name: "page-management-selftest", version: "1" });
  const previous = (await (await api("/notebooks")).json() as { view: { notebookId: string | null; pageId: string | null } }).view;
  await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${secret}`)));
  const call = async (name: string, args: Record<string, unknown>, expectedError = false) => {
    const result = await client.callTool({ name, arguments: args });
    assert.equal(!!result.isError, expectedError, `${name}: ${JSON.stringify(result.content)}`);
    return (result.content as { text: string }[])[0].text;
  };
  try {
    const source = await (await api("/notebooks", "POST", { title: "Page CRUD original", pages: 3 })).json() as Notebook;
    const target = await (await api("/notebooks", "POST", { title: "Page CRUD destination", pages: 1 })).json() as Notebook;
    const [first, second, third] = source.pages;
    await api("/view", "POST", { notebookId: source.id, pageId: first.id });
    await api(`/pages/${first.id}/snapshot`, "PUT", { png: png.toString("base64"), textBoxes: [{ text: "Copied ink", x: 10, y: 20, w: 30, h: 40 }] });
    const drawing = await fetch(`${base}/api/pages/${first.id}/drawing`, { method: "PUT", headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/octet-stream" }, body: Buffer.from([5, 6, 7]) });
    assert.ok(drawing.ok);
    const tools = (await client.listTools()).tools.map(t => t.name);
    for (const name of ["list_pages", "delete_pages", "reorder_pages", "duplicate_pages", "move_pages"]) assert.ok(tools.includes(name));
    const list = JSON.parse(await call("list_pages", { notebook_id: source.id }));
    assert.deepEqual(list.pages.map((p: { id: string }) => p.id), source.pages.map(p => p.id));
    await call("reorder_pages", { notebook_id: source.id, page_ids: [third.id, first.id, second.id] });
    const reordered = await (await api(`/notebooks/${source.id}`)).json() as Notebook;
    assert.deepEqual(reordered.pages.map(p => p.id), [third.id, first.id, second.id]);
    await api(`/notebooks/${source.id}/pages/reorder`, "POST", { pageIds: [first.id, first.id, second.id] }, 400);
    await call("delete_pages", { notebook_id: source.id, page_ids: [first.id, "unknown"] }, true);
    assert.equal((await (await api(`/notebooks/${source.id}`)).json() as Notebook).pages.length, 3);
    const duplicate = await (await api("/pages/duplicate", "POST", { pageIds: [first.id], targetNotebookId: target.id, afterPage: 0 })).json() as { notebook: Notebook; pages: Page[] };
    const copy = duplicate.pages[0];
    assert.notEqual(copy.id, first.id); assert.equal(copy.textBoxes[0].text, "Copied ink");
    assert.deepEqual(Buffer.from(await (await api(`/pages/${copy.id}/drawing`)).arrayBuffer()), Buffer.from([5, 6, 7]));
    await call("move_pages", { page_ids: [first.id], target_notebook_id: target.id, after_page: 0 });
    const movedView = await (await api("/notebooks")).json() as { view: { notebookId: string; pageId: string } };
    assert.equal(movedView.view.notebookId, target.id); assert.equal(movedView.view.pageId, first.id);
    await call("delete_pages", { page_ids: [first.id] });
    await api(`/pages/${first.id}/drawing`, "GET", undefined, 404);
    await api(`/pages/${first.id}/snapshot`, "PUT", { png: png.toString("base64") }, 404);
    await call("delete_pages", { notebook_id: source.id, page_ids: [second.id, third.id] });
    assert.equal((await (await api(`/notebooks/${source.id}`)).json() as Notebook).pages.length, 0);
    await call("view_page", { notebook_id: source.id, page_number: 1 }, true);
    await call("add_pages", { notebook_id: source.id, after_page: 0, background: "grid" });
    assert.equal((await (await api(`/notebooks/${source.id}`)).json() as Notebook).pages.length, 1);
    const anotherCopy = JSON.parse(await call("duplicate_pages", { page_ids: [copy.id], target_notebook_id: source.id }));
    assert.equal(anotherCopy.pages.length, 1);
    await call("delete_notebook", { notebook_id: source.id, direct: true });
    await api(`/notebooks/${source.id}`, "GET", undefined, 404);
    await call("delete_notebook", { notebook_id: target.id, direct: true });
    console.log("[page management MCP/REST] list/delete/reorder/duplicate/move, raw ink copy, current view, empty notebook refill and direct notebook deletion passed");
  } finally {
    if (previous.notebookId && previous.pageId) await api("/view", "POST", previous);
    await client.close();
  }
}
