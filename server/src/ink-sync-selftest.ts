import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import sharp from "sharp";
import { renderPage } from "./render.js";
import { DeletedPageError, Store, type Notebook, type StoreEvent } from "./store.js";

const clientId = "60de14ec-9430-4d8c-aea3-39a7c111f715";
const order = (sequence: number) => ({ clientId, sequence });
const png = await sharp({ create: { width: 10, height: 10, channels: 3, background: "#123456" } }).png().toBuffer();
const nextPng = await sharp({ create: { width: 10, height: 10, channels: 3, background: "#654321" } }).png().toBuffer();
const drawing = Buffer.from([1, 2, 3, 4]);
const boxes = [{ text: "Revision one", x: 10, y: 20, w: 30, h: 40 }];
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "claudebook-ink-sync-"));

try {
  let store = new Store(directory);
  const notebookId = store.listNotebooks()[0].id;
  const pageId = store.listNotebooks()[0].pages[0].id;
  const legacySnapshot = store.snapshotPath(pageId), legacyDrawing = store.drawingPath(pageId);
  fs.writeFileSync(legacySnapshot, png);
  fs.writeFileSync(legacyDrawing, Buffer.from([9]));

  const testSave = () => store.saveInk(pageId, png, drawing, boxes, 1, order(1));
  const oldDatabase = fs.readFileSync(path.join(directory, "db.json"), "utf8");
  const blockedDrawings = store.drawingsDir + ".backup";
  fs.renameSync(store.drawingsDir, blockedDrawings);
  try {
    fs.writeFileSync(store.drawingsDir, "");
    assert.throws(testSave);
  } finally {
    fs.unlinkSync(store.drawingsDir);
    fs.renameSync(blockedDrawings, store.drawingsDir);
  }

  const blockedDatabase = path.join(directory, "db.json.tmp");
  fs.mkdirSync(blockedDatabase);
  try {
    assert.throws(testSave);
    assert.throws(() => store.insertClientPages(notebookId, ["ink-test-optimistic"], "blank"));
  } finally { fs.rmdirSync(blockedDatabase); }
  assert.equal(fs.readFileSync(path.join(directory, "db.json"), "utf8"), oldDatabase);
  assert.equal(store.findPage("ink-test-optimistic"), undefined, "Failed creation must not be acknowledged on retry");
  assert.equal(store.snapshotPath(pageId), legacySnapshot);
  assert.deepEqual(fs.readFileSync(store.drawingPath(pageId)), Buffer.from([9]));
  assert.deepEqual(fs.readdirSync(store.snapshotsDir), [path.basename(legacySnapshot)]);
  assert.deepEqual(fs.readdirSync(store.drawingsDir), [path.basename(legacyDrawing)]);

  testSave();
  const firstSnapshot = store.snapshotPath(pageId), publishedDrawing = store.drawingPath(pageId);
  assert.notEqual(firstSnapshot, legacySnapshot);
  assert.notEqual(publishedDrawing, legacyDrawing);
  assert.deepEqual(fs.readFileSync(firstSnapshot), png);
  assert.deepEqual(fs.readFileSync(publishedDrawing), drawing);
  const render = renderPage(store, store.findPage(pageId)!.page, { claudeLayer: false });
  store.saveInk(pageId, nextPng, drawing, boxes, 1, order(2));
  assert.equal(fs.existsSync(firstSnapshot), false);
  assert.deepEqual(await sharp(await render).extract({ left: 0, top: 0, width: 1, height: 1 }).removeAlpha().raw().toBuffer(), Buffer.from([0x12, 0x34, 0x56]));
  const publishedSnapshot = store.snapshotPath(pageId);
  store.saveDrawing(pageId, Buffer.from([5]), 2, order(3));
  store.saveInk(pageId, png, Buffer.from([6]), [], 0, { clientId: clientId.toUpperCase(), sequence: 2 });
  assert.equal(store.snapshotPath(pageId), publishedSnapshot);
  assert.deepEqual(fs.readFileSync(store.drawingPath(pageId)), Buffer.from([5]));
  assert.deepEqual(store.findPage(pageId)?.page.textBoxes, boxes);

  const orphan = path.join(store.snapshotsDir, pageId + ".interrupted1.png");
  fs.writeFileSync(orphan, png);
  store = new Store(directory);
  assert.equal(fs.existsSync(orphan), false, "Interrupted staged files must be collectible");
  assert.equal(store.snapshotPath(pageId), publishedSnapshot);
  assert.deepEqual(fs.readFileSync(store.drawingPath(pageId)), Buffer.from([5]));

  const live: StoreEvent[] = [];
  store.on(event => live.push(event));
  const target = store.createNotebook("Ink destination");
  const copied = store.duplicatePages([pageId], target.id).pages[0];
  assert.deepEqual(fs.readFileSync(store.snapshotPath(copied.id)), nextPng);
  assert.deepEqual(fs.readFileSync(store.drawingPath(copied.id)), Buffer.from([5]));
  assert.equal(copied.inkUploadSequences, undefined);
  store.movePages([pageId], target.id);
  assert.ok(!store.deletedPageIds().includes(pageId));
  const paths = [store.snapshotPath(pageId), store.drawingPath(pageId)];
  store.deletePages(target.id, [pageId]);
  assert.ok(paths.every(file => !fs.existsSync(file)));
  assert.ok(live.some(event => event.type === "notebook" && event.deletedPageIds?.includes(pageId)));
  store = new Store(directory);
  assert.ok(store.deletedPageIds().includes(pageId));
  assert.throws(() => store.insertClientPages(target.id, [pageId], "blank"), DeletedPageError);
  assert.deepEqual(fs.readFileSync(store.drawingPath(copied.id)), Buffer.from([5]));
  console.log("[ink sync] atomic rollback, legacy migration, ordered uploads, copy, move and durable deletion passed");
} finally { fs.rmSync(directory, { recursive: true, force: true }); }

if (process.env.CLAUDEBOOK_SECRET) {
  const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787", secret = process.env.CLAUDEBOOK_SECRET;
  const api = async (route: string, method = "GET", body?: unknown, status = 200) => {
    const response = await fetch(base + "/api" + route, {
      method,
      headers: { Authorization: "Bearer " + secret, "Content-Type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    assert.equal(response.status, status, method + " " + route + ": " + (response.status === status ? "" : await response.text()));
    return response;
  };
  const notebook = await (await api("/notebooks", "POST", { title: "Atomic ink selftest" })).json() as Notebook;
  try {
    const pageId = notebook.pages[0].id;
    const route = "/pages/" + pageId + "/ink";
    const ink = { png: png.toString("base64"), drawing: drawing.toString("base64"), textBoxes: boxes, strokeCount: 1, clientOrder: order(2) };
    await api(route, "PUT", { ...ink, drawing: undefined }, 400);
    await api("/pages/nonexistent-page/ink", "PUT", ink, 404);
    await api(route, "PUT", ink);
    await api(route, "PUT", { ...ink, drawing: "AAAA", strokeCount: 2, clientOrder: order(1) });
    const page = (await (await api("/notebooks/" + notebook.id)).json() as Notebook).pages[0];
    assert.equal(page.snapshotVersion, 1);
    assert.equal(page.strokeCount, 1);
    assert.deepEqual(page.textBoxes, boxes);
    assert.deepEqual(Buffer.from(await (await api("/pages/" + pageId + "/drawing")).arrayBuffer()), drawing);
    await api("/notebooks/" + notebook.id + "/pages/delete", "POST", { pageIds: [pageId] });
    const library = await (await api("/notebooks")).json() as { deletedPageIds: string[] };
    assert.ok(library.deletedPageIds.includes(pageId));
    await api("/notebooks/" + notebook.id + "/pages", "POST", { pageIds: [pageId] }, 410);
    console.log("[ink sync REST] rejects partial updates, ignores older revisions and exposes confirmed deletions");
  } finally { await api("/notebooks/" + notebook.id, "DELETE"); }
}
