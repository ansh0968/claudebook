// Local combined-stream QA: chemistry metadata, physics transforms, graph parts,
// rendering item control, and folder/delete-request semantics through the real MCP API.
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { Item } from "./items.js";
import type { BBox, Point } from "./geometry.js";

const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787", secret = process.env.CLAUDEBOOK_SECRET;
if (secret) {
  const api = async (route: string, method = "GET", body?: unknown) => {
    const response = await fetch(`${base}/api${route}`, { method, headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    assert.ok(response.ok, `${route}: HTTP ${response.status}`);
    return response.json();
  };
  const client = new Client({ name: "combined-integration-selftest", version: "1" });
  await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${secret}`)));
  type Summary = { id: string; bbox: BBox; atoms?: Record<string, Point>; elements?: Record<string, string> };
  const tool = async (name: string, args: Record<string, unknown>) => {
    const result = await client.callTool({ name, arguments: args });
    assert.ok(!result.isError, `${name}: ${JSON.stringify(result.content)}`);
    return (result.content as { text: string }[])[0].text;
  };
  const call = async (name: string, args: Record<string, unknown>) => JSON.parse(await tool(name, args)) as { items: Summary[]; warnings?: unknown[] };
  const near = (a: number, b: number) => assert.ok(Math.abs(a - b) < 0.025, `${a} != ${b}`);
  const movedAtoms = (before: Record<string, Point>, after: Record<string, Point>, dx: number, dy: number) => {
    assert.deepEqual(Object.keys(after), Object.keys(before));
    for (const [id, [x, y]] of Object.entries(before)) { near(after[id][0], x + dx); near(after[id][1], y + dy); }
  };
  const movedBox = (before: BBox, after: BBox, dx: number, dy: number) => {
    near(after.x, before.x + dx); near(after.y, before.y + dy); near(after.w, before.w); near(after.h, before.h);
  };
  try {
    const folder = await api("/folders", "POST", { name: `Integration QA ${Date.now()}` }) as { id: string };
    const notebook = await api("/notebooks", "POST", { title: "Combined drawing QA", folderId: folder.id, pages: 2 }) as { id: string; pages: { id: string }[] };
    const [page_id, target_page_id] = notebook.pages.map(page => page.id);
    const saved = async (id = page_id) => ((await api(`/pages/${id}/claude`)) as { items: Item[] }).items;
    const drawn = await call("draw_on_page", { page_id, items: [{ type: "molecule", smiles: "CC(=O)O", show_carbons: true, explicit_h: true, x: 160, y: 200, size: 220, rotation: 33 }] });
    assert.equal(drawn.items.length, 1); assert.equal(drawn.warnings, undefined);
    const raw = (await saved())[0], summary = drawn.items[0], [cx, cy] = raw.rotation_center!;
    assert.ok(raw.rotation_center && raw.atoms && raw.elements);
    const radians = 33 * Math.PI / 180;
    for (const [id, [x, y]] of Object.entries(raw.atoms!)) {
      near(summary.atoms![id][0], cx + (x - cx) * Math.cos(radians) - (y - cy) * Math.sin(radians));
      near(summary.atoms![id][1], cy + (x - cx) * Math.sin(radians) + (y - cy) * Math.cos(radians));
    }
    assert.deepEqual(summary.elements, raw.elements);
    const moved = await call("move_items", { page_id, ids: [raw.id], dx: 31, dy: -17 });
    movedAtoms(summary.atoms!, moved.items[0].atoms!, 31, -17);
    movedBox(summary.bbox, moved.items[0].bbox, 31, -17);
    const rawMoved = (await saved())[0];
    movedAtoms(raw.atoms!, rawMoved.atoms!, 31, -17);
    near(rawMoved.rotation_center![0], cx + 31); near(rawMoved.rotation_center![1], cy - 17);
    const copied = await call("copy_items", { page_id, target_page_id, ids: [raw.id], offset: [-21, 49] });
    assert.notEqual(copied.items[0].id, raw.id);
    movedAtoms(moved.items[0].atoms!, copied.items[0].atoms!, -21, 49);
    movedBox(moved.items[0].bbox, copied.items[0].bbox, -21, 49);
    const rawCopy = (await saved(target_page_id))[0];
    movedAtoms(rawMoved.atoms!, rawCopy.atoms!, -21, 49);
    near(rawCopy.rotation_center![0], rawMoved.rotation_center![0] - 21); near(rawCopy.rotation_center![1], rawMoved.rotation_center![1] + 49);
    assert.deepEqual((await saved())[0], rawMoved, "Copying must leave source metadata untouched");

    const items = [{ type: "axes", origin: [400, 800], xrange: [-2, 3], yrange: [-1, 3], unit: 50, name: "combined-axes" }, { type: "plot", axes: "combined-axes", fn: "x^2/2", from: -2, to: 2 }];
    const before = await saved();
    const plain = await call("draw_on_page", { page_id, items, dry_run: true });
    const shifted = await call("draw_on_page", { page_id, items, dry_run: true, offset: [35, 19] });
    assert.equal(shifted.items.length, 2); assert.equal(shifted.warnings, undefined);
    for (let n = 0; n < 2; n++) movedBox(plain.items[n].bbox, shifted.items[n].bbox, 35, 19);
    assert.deepEqual(await saved(), before, "Both graph dry runs must leave the store unchanged");
    const graph = await call("draw_on_page", { page_id, items, offset: [35, 19] });
    for (let n = 0; n < 2; n++) movedBox(plain.items[n].bbox, graph.items[n].bbox, 35, 19);
    const graphSaved = (await saved()).slice(1);
    assert.deepEqual(graphSaved[0].graph!.origin, [435, 819]);
    assert.deepEqual(graphSaved[1].graph!.origin, [435, 819]);

    await tool("delete_notebook", { notebook_id: notebook.id });
    const pending = await api(`/notebooks/${notebook.id}`) as { folderId: string; deleteRequestedAt?: string };
    assert.equal(pending.folderId, folder.id); assert.ok(pending.deleteRequestedAt, "Claude requests deletion, preserving the folder notebook until confirmation");
    const row = (await tool("list_notebooks", {})).split("\n").find(line => line.includes(notebook.id));
    assert.match(row!, /waiting for the user to confirm deletion/);
    await api(`/notebooks/${notebook.id}/delete-request`, "DELETE");
    assert.equal((await api(`/notebooks/${notebook.id}`)).deleteRequestedAt, undefined);
    console.log("[integration MCP] actual rotated molecule atom summaries + move/copy, graph offset/dry_run, folder pending-delete status passed");
  } finally { await client.close(); }
}
